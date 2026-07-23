import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

/// The handshake brain + connection-ownership relay for one attach
/// generation. Drains `BridgeConnectionActor.frames`, validates `hello` in
/// the spec-fixed order (see the spec's "Handshake and version negotiation"),
/// drives `promoteToActive`, and relays two seams downstream so later work
/// doesn't have to reach into `BridgeConnectionActor` directly or into each
/// other:
///
///  - `frameSink` — every validated post-handshake envelope, generation-tagged.
///  - `connectionLostSink` — the identity of a connection a replacement just
///    closed, so its pending permission state can be default-denied.
///
/// `actor`-isolated: the only state this type owns is the frame-consuming
/// `Task` handle, but every real side effect (send/promote/close) already
/// hops into `BridgeConnectionActor`'s own isolation regardless, so there is
/// no correctness upside to anything more elaborate — a plain class would
/// still need a lock around `consumeTask` to be race-free, and an actor gets
/// that for free while matching the sibling type's shape.
actor BridgeConnectionSupervisor {
    /// Both sinks run inline on the single sequential loop that also
    /// processes every `hello` for this attach (see `start()`) — a
    /// concurrent replacement connection's 5 s hello deadline
    /// (`BridgeTunables.helloDeadline`) keeps ticking independently while a
    /// sink call is in flight, so an implementation that blocks on a
    /// user-facing decision (rather than kicking that decision off
    /// asynchronously and returning) can starve the exact "restarted helper
    /// replaces a wedged predecessor" grace period the spec's connection-
    /// ownership rule exists to serve. Implementations must return promptly.
    typealias FrameSink = @Sendable (BridgeEnvelope, BridgeConnectionActor.Generation) async -> Void
    /// See `FrameSink`'s doc comment — the same promptness contract applies.
    typealias ConnectionLostSink = @Sendable (BridgeConnectionActor.ConnectionID) async -> Void

    /// Protocol strings this app build accepts in `hello.proto`. Mirrors
    /// `BridgeHelperCommand.supportedProtocols` on the helper side — declared
    /// independently because the app and the helper are different targets
    /// with no shared dependency between them; the wire is the contract, not
    /// shared Swift code, so the two lists must be kept in sync by hand.
    static let supportedProtocols = ["awesomux-bridge-v1"]

    private let connectionActor: BridgeConnectionActor
    private let expectedToken: String
    private let expectedSession: String
    private let supportedProtocols: [String]
    private let frameSink: FrameSink
    private let connectionLostSink: ConnectionLostSink
    private let wallNow: @Sendable () -> Date
    private var consumeTask: Task<Void, Never>?
    /// The generation of whichever connection is currently active, per the
    /// last successful promotion this handler ran. An `.envelope` delivery
    /// can be sitting in `frames` behind a not-yet-processed `hello` that
    /// replaces its own connection (both frames land on the actor's single
    /// stream from independent dispatch-source callbacks, in whatever order
    /// the actor happened to service them) — by the time this handler's
    /// strictly-sequential loop reaches that envelope, its connection may
    /// already be dead and its `connectionLostSink` already fired. Comparing
    /// against this field is how `handle(_:)` catches that and drops the
    /// stale delivery instead of resurrecting pending state for a connection
    /// that no longer exists.
    private var activeGeneration: BridgeConnectionActor.Generation?

    init(
        connectionActor: BridgeConnectionActor,
        expectedToken: String,
        expectedSession: String,
        supportedProtocols: [String] = BridgeConnectionSupervisor.supportedProtocols,
        wallNow: @escaping @Sendable () -> Date = Date.init,
        frameSink: @escaping FrameSink,
        connectionLostSink: @escaping ConnectionLostSink
    ) {
        // An empty token/session would make `constantTimeEquals`'s
        // equal-length-empty-arrays case (and a plain `==` on two empty
        // sessions) pass for free — a minting bug that silently degrades
        // the handshake to no real authentication, rather than one that
        // fails loudly. Crashing here trades a quiet auth bypass for a
        // noisy, immediate one, which is the right side of that trade for a
        // per-attach secret that should never legitimately be empty.
        precondition(!expectedToken.isEmpty, "BridgeConnectionSupervisor requires a non-empty token")
        precondition(!expectedSession.isEmpty, "BridgeConnectionSupervisor requires a non-empty session")
        self.connectionActor = connectionActor
        self.expectedToken = expectedToken
        self.expectedSession = expectedSession
        self.supportedProtocols = supportedProtocols
        self.wallNow = wallNow
        self.frameSink = frameSink
        self.connectionLostSink = connectionLostSink
    }

    /// Starts the underlying listener and begins draining its frame stream.
    /// Idempotent the same way `BridgeConnectionActor.start()` is — but that
    /// idempotence is exactly why the reservation guard must run *before*
    /// the first `await`: two overlapping `start()` calls are two separate
    /// actor-isolated invocations that can each reach a suspension point and
    /// interleave, so checking `consumeTask == nil` after an `await` would
    /// let both see `nil` and each install their own consuming `Task` — one
    /// silently orphaned, splitting `frames` delivery between two loops
    /// instead of one. Reserving the slot synchronously, before any `await`,
    /// closes that window.
    func start() async {
        guard consumeTask == nil else { return }
        // Captures the stream itself, not `connectionActor` — `frames` is a
        // `nonisolated let`, so hoisting it here means the closure below
        // holds no strong reference to the actor at all. That matters for
        // teardown: this type's own `deinit` cancels the task as a fast
        // path, but cancellation alone doesn't force an `AsyncStream`
        // iteration to stop. What actually guarantees this loop ends is
        // `connectionActor`'s reference count reaching zero once nothing
        // (including this closure) still holds it, which runs its own
        // `deinit` → `frameContinuation.finish()` → this `for await` resumes
        // with `nil`. Capturing `connectionActor` here instead would have
        // kept it alive forever through this very closure — a resource leak
        // (open listener socket, live handshake acceptor with a stale
        // token) for any caller that drops the supervisor without an
        // explicit `shutdown()`.
        let frameStream = connectionActor.frames
        await connectionActor.setConnectionLostHandler { [weak self] connection, generation in
            await self?.handleUnexpectedConnectionLoss(connection, generation: generation)
        }
        consumeTask = Task { [weak self] in
            for await delivery in frameStream {
                guard let self else { return }
                await self.handle(delivery)
            }
        }
        await connectionActor.start()
    }

    /// Fast-path teardown for a supervisor that is simply dropped without an
    /// explicit `shutdown()` call — mirrors `BridgeConnectionActor.deinit`'s
    /// own belt-and-braces cancellation of everything it owns. The `start()`
    /// doc comment above covers why this alone isn't load-bearing for
    /// correctness (the stream-finishes-on-actor-deinit path is), but there's
    /// no reason to leave a cancellable task unpredictably running longer
    /// than it has to.
    deinit {
        consumeTask?.cancel()
    }

    /// App → helper passthrough so permission-decision callers never touch
    /// `BridgeConnectionActor` directly — they route through the supervisor's
    /// handshake/generation bookkeeping instead.
    func sendPermissionDecision(
        envelope: BridgeEnvelope,
        generation: BridgeConnectionActor.Generation
    ) async -> Bool {
        await connectionActor.send(envelope, generation: generation)
    }

    /// Awaits the consuming `Task`'s actual end, not just its cancellation
    /// request — `Task.cancel()` doesn't abort an in-flight `await` on
    /// `frameSink`/`connectionLostSink`, so returning right after `cancel()`
    /// would let a sink call keep running (and mutate downstream state)
    /// after a caller believes shutdown is complete. `connectionActor
    /// .shutdown()` finishes `frames`, which is what lets the loop's *next*
    /// iteration exit; the final `await task?.value` is what makes this
    /// method itself a true quiescence boundary.
    func shutdown() async {
        let task = consumeTask
        consumeTask = nil
        task?.cancel()
        await connectionActor.shutdown()
        await task?.value
    }

    // MARK: - Frame handling

    private func handle(_ delivery: BridgeConnectionActor.FrameDelivery) async {
        switch delivery.frame {
        case .handshake(.hello(let proto, let token, let session, _, _)):
            await handleHello(
                proto: proto, token: token, session: session,
                connection: delivery.connection, generation: delivery.generation
            )
        case .handshake:
            // `BridgeConnectionActor.consume(_:)` closes a connection itself
            // on any inbound handshake frame other than `hello` (see
            // "inbound hello ack closes the connection" in
            // BridgeConnectionActorTests) — a `hello-ack`/`hello-nack` sent
            // *to* the app never reaches `frames`. Nothing to do here unless
            // that invariant changes.
            break
        case .envelope(let envelope):
            // The actor only yields `.envelope` frames once a connection is
            // promoted and direction-allowlisted (`activeConnection == id` in
            // its own `consume(_:)`), so every envelope reaching here is
            // already post-handshake — the frame sink never sees a handshake
            // frame. That check was made when the actor read the bytes,
            // though, not when this handler runs — see `activeGeneration`'s
            // doc comment for why a stale one must still be dropped here.
            guard delivery.generation == activeGeneration else { return }
            await frameSink(envelope, delivery.generation)
        }
    }

    private func handleUnexpectedConnectionLoss(
        _ connection: BridgeConnectionActor.ConnectionID,
        generation: BridgeConnectionActor.Generation
    ) async {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        await connectionLostSink(connection)
    }

    /// Validation order is spec-fixed ("Handshake and version negotiation"):
    /// proto, then token (constant-time), then session — any failure closes
    /// the connection without running the later checks. An unsupported proto
    /// is the one case that gets a reply (`hello-nack`); every other failure
    /// closes silently, per the spec's "Token mismatch"/"Unknown protocol
    /// version" failure-mode table.
    private func handleHello(
        proto: String,
        token: String,
        session: String,
        connection: BridgeConnectionActor.ConnectionID,
        generation: BridgeConnectionActor.Generation
    ) async {
        guard supportedProtocols.contains(proto) else {
            _ = await connectionActor.send(.helloNack(supported: supportedProtocols), generation: generation)
            await connectionActor.close(connection)
            return
        }
        // Constant-time per the spec's Security analysis — reuses
        // `BridgeFrameReader`'s own compare (hoisted to `package` access)
        // rather than a second hand-rolled implementation that could
        // subtly diverge (e.g. short-circuiting on the first differing byte).
        guard BridgeFrameReader.constantTimeEquals(token, expectedToken) else {
            await connectionActor.close(connection)
            return
        }
        // `session` is a correlation id, not a secret — plain `==` matches
        // how `BridgeFrameReader` validates envelope `session` fields.
        guard session == expectedSession else {
            await connectionActor.close(connection)
            return
        }

        guard let promotion = await connectionActor.promoteToActive(connection) else {
            // `promoteToActive` already closed `connection` itself (generation
            // counter exhausted, or the connection vanished between the frame
            // landing and this handler running) — nothing left to ack.
            return
        }
        activeGeneration = promotion.generation
        if let replaced = promotion.replacedConnection {
            await connectionLostSink(replaced)
        }
        _ = await connectionActor.send(
            .helloAck(session: expectedSession, proto: proto, ts: wallNow().timeIntervalSince1970),
            generation: promotion.generation
        )
    }
}
