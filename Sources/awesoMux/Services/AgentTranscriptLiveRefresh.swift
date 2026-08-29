import AwesoMuxCore
import Foundation

// MARK: - AgentTranscriptRenderGate

/// Orders the cache writes of every render of one transcript tab, so a slow
/// render can never land on top of a newer one.
///
/// `Task.isCancelled` cannot do this job, twice over. A render runs on a
/// detached task, where `Task.isCancelled` reports *that* task rather than the
/// loop that dispatched it; and `.task(id:)` cancellation does not reach an
/// already-dispatched render at all, so a superseded SwiftUI task generation
/// can still finish late and overwrite newer bytes — the transcript visibly
/// moving backwards on screen. A render therefore claims a stamp before it
/// starts and may write only while that stamp is still the newest one claimed.
/// Cancelling a loop supersedes its in-flight render by claiming a stamp
/// nobody will use.
///
/// The view owns this in `@State` rather than the loop owning it, because it
/// has to outlive the loop it belongs to — the same reason
/// `DocumentPaneView.watcherReloadGeneration` is view state.
final class AgentTranscriptRenderGate: Sendable {
    private let lock = NSLock()
    // `nonisolated(unsafe)` promise: read and written only under `lock`.
    nonisolated(unsafe) private var latest = 0

    init() {}

    /// Stamps a render that is about to start.
    func claim() -> Int {
        lock.withLock {
            latest += 1
            return latest
        }
    }

    /// Whether the render holding `stamp` is still the newest one.
    ///
    /// Asked as the first statement of the cache write's own critical section,
    /// not merely before the write is attempted: `AgentTranscriptStore` writes
    /// under a different lock, so an answer produced outside it can be true and
    /// already stale by the time the bytes land. There is no window between the
    /// answer and the write only because the two share one lock.
    func isCurrent(_ stamp: Int) -> Bool {
        lock.withLock { latest == stamp }
    }

    /// Supersedes every in-flight render without starting one.
    func invalidate() {
        _ = claim()
    }
}

// MARK: - AgentTranscriptLiveRefresh

/// Keeps one mounted agent-transcript tab current while its session keeps
/// appending to the provider's JSONL.
///
/// Full discovery runs once; the resolved `AgentTranscript` is then pinned and
/// every subsequent pass re-opens *that* file. Re-opening is not incidental —
/// a `SecureFileReadHandle` can only vouch for the length it validated, so
/// appended bytes are invisible until the path is opened again, and opening it
/// again re-runs the owner, regular-file, and symlink checks against the
/// current inode (ADR-0033).
@MainActor
final class AgentTranscriptLiveRefresh {

    // MARK: Seams

    /// Full discovery, reporting its typed failure rather than an erased `nil`.
    ///
    /// The distinction is load-bearing: `.notFound` from discovery is the
    /// ordinary "the agent has not written the log yet" case and is exactly
    /// what the bounded retry exists for, while `.wrongOwner` is a refusal that
    /// repeats. Erasing both to `nil` made the documented three-attempt
    /// recovery unreachable for every lookup failure.
    typealias DiscoverOperation =
        @Sendable () async -> Result<AgentTranscript, AgentTranscriptUnavailable>

    /// Re-reads, re-renders, and stores `transcript`, consulting the second
    /// argument inside the cache write's critical section.
    typealias RefreshOperation =
        @Sendable (AgentTranscript, @Sendable () -> Bool) async ->
        Result<URL, AgentTranscriptOpenFailure>

    /// Starts observing `url`, invoking the callback for every filesystem
    /// event, and returns the teardown.
    typealias WatchOperation =
        @MainActor (URL, @MainActor @escaping () -> Void) ->
        @MainActor () ->
        Void

    // MARK: Failure policy

    enum FailureResponse: Equatable {
        case rediscover
        case giveUp
    }

    /// Each attempt re-runs full discovery, so this is not the same input three
    /// times. Past it the loop stops and the tab keeps its last good render —
    /// the behaviour a transcript tab had before it refreshed at all.
    ///
    /// Three failures *in a row*, not three in a lifetime: a successful render
    /// resets the count. A six-hour session that hits three unrelated transient
    /// blips has recovered from each of them, and spending a lifetime budget on
    /// them would silently stop refreshing a tab that is working.
    static let maximumRediscoveries = 3

    /// Exhaustive on purpose: a new failure case should be a compile error
    /// here, not a silent inheritance of whichever branch a `default` picked.
    static func response(to failure: AgentTranscriptOpenFailure) -> FailureResponse {
        switch failure {
        case .cacheWriteFailed:
            // Not "continue, the next append retries": if the *final* append's
            // write fails there is no next event, and the tab is stale for good.
            return .rediscover
        case .unavailable(let reason):
            switch reason {
            case .notFound:
                // Source gone or moved. Discovery finds it, or gives up for us.
                return .rediscover
            case .unreadable(.unreadable):
                // Transient I/O, or the inode was replaced under us.
                return .rediscover
            case .unreadable(.wrongOwner), .unreadable(.notRegularFile), .unreadable(.tooLarge):
                // Security and size refusals, not transients — the same file
                // fails the same way every time.
                return .giveUp
            case .remoteExecution, .unsupportedAgent, .invalidSessionID, .noSessionIdentity,
                .searchLimitReached:
                return .giveUp
            }
        }
    }

    // MARK: State

    private enum Outcome {
        case cancelled
        case giveUp
        case rediscover
    }

    private let gate: AgentTranscriptRenderGate
    private let onPin: @MainActor (AgentTranscript) -> Void
    private let discover: DiscoverOperation
    private let refresh: RefreshOperation
    private let watch: WatchOperation
    private var pinned: AgentTranscript?
    /// Consecutive failures, reset by any successful render (see
    /// `maximumRediscoveries`). An instance property rather than a `run()`
    /// local so `render` can reset it where the success actually happens.
    private var rediscoveries = 0

    // MARK: Lifecycle

    init(
        gate: AgentTranscriptRenderGate,
        pinned: AgentTranscript?,
        onPin: @MainActor @escaping (AgentTranscript) -> Void,
        discover: @escaping DiscoverOperation,
        refresh: @escaping RefreshOperation,
        watch: @escaping WatchOperation
    ) {
        self.gate = gate
        self.pinned = pinned
        self.onPin = onPin
        self.discover = discover
        self.refresh = refresh
        self.watch = watch
    }

    /// The production loop for one document tab.
    convenience init(
        identity: AgentTranscriptIdentity,
        configHome: URL,
        gate: AgentTranscriptRenderGate,
        pinned: AgentTranscript?,
        store: AgentTranscriptStore = AgentTranscriptStore(),
        onPin: @MainActor @escaping (AgentTranscript) -> Void
    ) {
        self.init(
            gate: gate,
            pinned: pinned,
            onPin: onPin,
            discover: {
                // `.local` because ADR-0033 leaves no other supported value —
                // an operational fact, not a proof about this tab. A decoded
                // identity is restored with no filesystem resolution behind it.
                AgentTranscriptImporter.open(
                    agentKind: identity.agentKind,
                    executionPlan: .local,
                    configHome: configHome,
                    reportedSessionID: identity.sessionID
                )
            },
            refresh: { transcript, shouldCommit in
                AgentTranscriptOpener.refresh(transcript, store: store, shouldCommit: shouldCommit)
            },
            watch: { url, onChange in
                // `.leadingEdge`, because the stream in `follow` coalesces but
                // does not rate-limit: it bounds how many renders run at once,
                // not how often one starts, so an actively-appending agent
                // would drive back-to-back full-window reads for the length of
                // its run. `.debounced` is the opposite failure — its restart
                // is unconditional, so the same stream postpones delivery for
                // as long as it lasts. The leading edge bounds the rate without
                // delaying the first event or starving under the last.
                let watcher = DocumentFileWatcher(
                    url: url,
                    coalescing: .leadingEdge,
                    onChange: onChange
                )
                watcher.start()
                return { watcher.stop() }
            }
        )
    }

    // MARK: Running

    /// Runs until the transcript stops being followable or the enclosing
    /// `.task` is cancelled.
    func run() async {
        while !Task.isCancelled {
            let transcript: AgentTranscript
            if let pinned {
                transcript = pinned
            } else {
                switch await discoverDetached() {
                case .success(let discovered):
                    // `Task.detached` does not inherit cancellation, so nothing
                    // above stopped discovery when the enclosing `.task(id:)`
                    // went away. Without this the loop still pins, still writes
                    // the view's `@State` through `onPin`, and still arms a
                    // watcher, for a generation that no longer exists.
                    guard !Task.isCancelled else { return }
                    pinned = discovered
                    onPin(discovered)
                    transcript = discovered
                case .failure(let reason):
                    guard consumeRediscovery(after: .unavailable(reason)) else { return }
                    continue
                }
            }

            switch await follow(transcript) {
            case .cancelled, .giveUp:
                return
            case .rediscover:
                guard consumeRediscovery(after: nil) else { return }
                pinned = nil
            }
        }
    }

    /// Charges one attempt against the consecutive-failure budget, answering
    /// whether the loop may go round again.
    ///
    /// - Parameter failure: The discovery failure to classify, or `nil` when
    ///   the caller has already classified one as `.rediscover`.
    private func consumeRediscovery(after failure: AgentTranscriptOpenFailure?) -> Bool {
        if let failure, Self.response(to: failure) == .giveUp { return false }
        rediscoveries += 1
        return rediscoveries <= Self.maximumRediscoveries
    }

    private func discoverDetached() async -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        let discover = self.discover
        // Discovery walks the provider's session tree and opens a file; none of
        // that belongs on the main actor. Same priority as the render it feeds:
        // a render the user is watching must never wait behind lower-priority
        // work, and discovery is on the path to the first one.
        return await Task.detached(priority: .userInitiated) { await discover() }.value
    }

    /// Watches one pinned transcript and renders it on every event, one at a
    /// time.
    private func follow(_ transcript: AgentTranscript) async -> Outcome {
        // `.bufferingNewest(1)` bounds concurrency, not frequency: a burst
        // collapses to one follow-up and the *last* append is never dropped,
        // which a "skip while a render is in flight" policy would strand. The
        // rate limit lives in the watcher's leading-edge window.
        let (ticks, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let stop = watch(transcript.resolvedURL) { continuation.yield(()) }
        defer { stop() }

        let gate = self.gate
        return await withTaskCancellationHandler {
            // Catch-up render: the file can grow between discovery and the
            // watch being armed, and those bytes get no event of their own.
            if let outcome = await render(transcript) { return outcome }
            // Sequential by construction — the body is awaited before the next
            // tick is consumed, so two renders never overlap.
            for await _ in ticks {
                if let outcome = await render(transcript) { return outcome }
            }
            return .cancelled
        } onCancel: {
            // `defer { continuation.finish() }` would be circular: it runs only
            // once iteration has already exited, and iteration is exactly what
            // needs to stop. `BridgeConnectionSupervisor.start()` carries the
            // same warning.
            continuation.finish()
            // Nothing can cancel a detached render that is already running;
            // superseding its stamp is what stops it writing.
            gate.invalidate()
        }
    }

    /// One render pass. `nil` means "keep following".
    private func render(_ transcript: AgentTranscript) async -> Outcome? {
        guard !Task.isCancelled else { return .cancelled }
        let gate = self.gate
        let stamp = gate.claim()
        let refresh = self.refresh
        // Detached because rendering reads and converts up to 32 MiB and the
        // main actor has to stay free to scroll the document it is about to
        // replace — but not demoted for it: this render is the thing the user
        // is looking at, and running it below the discovery that feeds it was
        // a priority inversion.
        let result = await Task.detached(priority: .userInitiated) {
            await refresh(transcript) { gate.isCurrent(stamp) }
        }.value
        guard !Task.isCancelled else { return .cancelled }

        switch result {
        case .success:
            // The budget counts consecutive failures, so a render that landed
            // clears whatever transient preceded it.
            rediscoveries = 0
            return nil
        case .failure(let failure):
            switch Self.response(to: failure) {
            case .rediscover: return .rediscover
            case .giveUp: return .giveUp
            }
        }
    }
}
