import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// All coverage runs against the injected closure seams — no live ssh, no real
// socket binds. A spy exec channel records the exact assembled commands (and
// can inject failures per command); a fake make-listener records bind/shutdown
// so make-before-break ordering and rollback are observable on one timeline.
@Suite("Bridge attach preflight")
struct BridgeAttachPreflightTests {
    private static let session = TerminalSessionID(rawValue: "abc123-bridge")!
    private static let request = BridgeAttachPreflight.Request(
        session: session,
        remote: RemoteTarget(user: "alice", host: "box"),
        controlPath: "/tmp/ctl/%C",
        remoteHome: "/Users/example",
        helperPath: "/usr/local/bin/awesomux-remote-helper",
        commandBuilder: { channel in
            AmxBackend.bridgeEnvironmentPrefixedRemoteCommand(
                stateFilePath: channel.stateFilePath,
                session: session,
                helperPath: "/usr/local/bin/awesomux-remote-helper",
                remoteCommand: "zmx attach remote-id"
            )
        }
    )

    // MARK: - Happy path + ledger threading

    @Test("a clean attach resolves ready with the env-prefixed spawn command")
    func cleanAttachResolvesReady() async {
        let harness = Harness()
        let outcome = await harness.preflight.attach(Self.request)
        guard case let .ready(channel, command) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        #expect(channel.gen == 1)
        #expect(command.contains("'AWESOMUX_BRIDGE_STATE=/Users/example/.awesomux/bridge/abc123-bridge.json'"))
        #expect(command.hasSuffix("zmx attach remote-id"))
    }

    @Test("previousGeneration threads ledger → mint so gen strictly increments across reattaches")
    func generationIncrementsAcrossReattaches() async {
        let harness = Harness()
        var gens: [Int] = []
        for _ in 0..<3 {
            let outcome = await harness.preflight.attach(Self.request)
            guard case let .ready(channel, _) = outcome else {
                Issue.record("expected ready, got \(outcome)")
                return
            }
            gens.append(channel.gen)
        }
        #expect(gens == [1, 2, 3])
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 3)
    }

    // MARK: - Make-before-break ordering

    @Test("the old generation's forward/socket/listener survive until publish, then break")
    func makeBeforeBreakOrdering() async {
        let harness = Harness()
        let first = await harness.preflight.attach(Self.request)
        let second = await harness.preflight.attach(Self.request)
        guard case let .ready(channel1, _) = first, case .ready = second else {
            Issue.record("expected two ready outcomes")
            return
        }

        let events = await harness.timeline.events
        let cmds = Self.execCommands(events)
        let forwards = cmds.indices.filter { cmds[$0].contains("-O forward") }
        let publishes = cmds.indices.filter { cmds[$0].contains("cat >") }
        let cancels = cmds.indices.filter { cmds[$0].contains("-O cancel") }

        #expect(forwards.count == 2)
        #expect(publishes.count == 2)
        // Exactly one cancel across a single reattach — no dead-forward pileup.
        #expect(cancels.count == 1)
        // New forward before its publish; old forward cancelled only after publish.
        #expect(publishes[1] > forwards[1])
        #expect(cancels[0] > publishes[1])

        // The old listener is shut down only after the new publish committed.
        let shutdownIdx = events.firstIndex(of: "shutdown:/tmp/fake-listener-1.sock")
        let publishEventIdxs = events.indices.filter { events[$0].contains("cat >") }
        #expect(shutdownIdx != nil)
        #expect((shutdownIdx ?? 0) > publishEventIdxs[1])

        // The old socket is removed by its exact ledger path, never the new one.
        #expect(cmds.contains { $0.contains("rm -f") && $0.contains(channel1.remoteSocketPath) })
    }

    @Test("repeated reattaches cancel exactly one prior forward each — no accumulation")
    func repeatedReattachesDoNotAccumulateForwards() async {
        let harness = Harness()
        for _ in 0..<3 { _ = await harness.preflight.attach(Self.request) }
        let cmds = Self.execCommands(await harness.timeline.events)
        // 3 attaches → forwards on each, cancels only on the two reattaches.
        #expect(cmds.filter { $0.contains("-O forward") }.count == 3)
        #expect(cmds.filter { $0.contains("-O cancel") }.count == 2)
        #expect(cmds.filter { $0.contains("rm -f") && $0.contains("awesomux-bridge-") }.count == 2)
    }

    // MARK: - No glob anywhere

    @Test("no executed command contains a glob")
    func noGlobInAnyExecutedCommand() async {
        let harness = Harness()
        _ = await harness.preflight.attach(Self.request)
        _ = await harness.preflight.attach(Self.request)
        for command in Self.execCommands(await harness.timeline.events) {
            #expect(!command.contains("*"), "glob found: \(command)")
        }
    }

    // MARK: - Rollback per mid-sequence failure step

    @Test("step 2 — a listener bind failure degrades and stages no remote resources")
    func listenerBindFailureRollsBack() async {
        let harness = Harness(listenerFailsOn: { $0 == 1 })
        let outcome = await harness.preflight.attach(Self.request)
        #expect(outcome == .degraded(.listenerFailed))
        let cmds = Self.execCommands(await harness.timeline.events)
        #expect(cmds.isEmpty) // never reached forward/admission/publish
    }

    @Test("a command assembly failure closes the listener before any remote mutation")
    func commandAssemblyFailureRollsBackBeforeForward() async {
        let harness = Harness()
        let request = BridgeAttachPreflight.Request(
            session: Self.session,
            remote: RemoteTarget(user: "alice", host: "box"),
            controlPath: "/tmp/ctl/%C",
            remoteHome: "/Users/example",
            helperPath: "/usr/local/bin/awesomux-remote-helper",
            commandBuilder: { _ in nil }
        )

        let outcome = await harness.preflight.attach(request)
        #expect(outcome == .degraded(.commandFailed))
        let events = await harness.timeline.events
        #expect(Self.execCommands(events).isEmpty)
        #expect(events == [
            "bind:/tmp/fake-listener-1.sock",
            "shutdown:/tmp/fake-listener-1.sock"
        ])
    }

    @Test("step 3 forward — a forward failure best-effort cancels the new forward and closes the listener")
    func forwardFailureRollsBackNewResources() async {
        let harness = Harness(failIf: { $0.contains("-O forward") })
        let outcome = await harness.preflight.attach(Self.request)
        #expect(outcome == .degraded(.forwardFailed))
        let events = await harness.timeline.events
        let cmds = Self.execCommands(events)
        #expect(cmds.contains { $0.contains("-O forward") })
        // Cancellation can race a forward the master already accepted, so the
        // rollback always attempts the cancel (a no-op if it never registered).
        #expect(cmds.contains { $0.contains("-O cancel") })
        #expect(!cmds.contains { $0.contains("cat >") }) // never published
        #expect(events.contains("shutdown:/tmp/fake-listener-1.sock"))
    }

    @Test("step 3 admission — a rejected owner check cancels the new forward and closes the listener")
    func admissionRejectionRollsBackNewResources() async {
        // Group/world-accessible remote socket → not owner-only → rejected.
        let harness = Harness(admissionMode: { "660" })
        let outcome = await harness.preflight.attach(Self.request)
        #expect(outcome == .degraded(.admissionRejected))
        let events = await harness.timeline.events
        let cmds = Self.execCommands(events)
        #expect(cmds.contains { $0.contains("-O forward") })
        #expect(cmds.contains { $0.contains("stat -c %a") })
        #expect(cmds.contains { $0.contains("-O cancel") }) // new forward cancelled
        #expect(!cmds.contains { $0.contains("cat >") })    // never published
        #expect(events.contains("shutdown:/tmp/fake-listener-1.sock"))
    }

    @Test("step 4 publish — a publish failure cancels the new forward and closes the listener")
    func publishFailureRollsBackNewResources() async {
        let harness = Harness(failIf: { $0.contains("cat >") })
        let outcome = await harness.preflight.attach(Self.request)
        #expect(outcome == .degraded(.publishFailed))
        let events = await harness.timeline.events
        let cmds = Self.execCommands(events)
        #expect(cmds.contains { $0.contains("cat >") })
        #expect(cmds.contains { $0.contains("-O cancel") })
        #expect(events.contains("shutdown:/tmp/fake-listener-1.sock"))
    }

    @Test("a mid-sequence failure leaves the old generation working and does not advance the ledger")
    func failureLeavesOldGenerationIntact() async {
        // First attach succeeds (gen 1). Second attach fails at publish. The old
        // gen's listener is never shut down, and the ledger stays at gen 1 so the
        // NEXT successful attach mints gen 2 (the failed attach consumed nothing).
        let box = FailBox()
        let harness = Harness(failIf: { command in box.active && command.contains("cat >") })

        let first = await harness.preflight.attach(Self.request)
        guard case .ready = first else { Issue.record("first should be ready"); return }

        box.active = true
        let second = await harness.preflight.attach(Self.request)
        #expect(second == .degraded(.publishFailed))
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 1)
        // The old (first) listener is untouched by the failed reattach.
        let eventsAfterFailure = await harness.timeline.events
        #expect(!eventsAfterFailure.contains("shutdown:/tmp/fake-listener-1.sock"))

        box.active = false
        let third = await harness.preflight.attach(Self.request)
        guard case let .ready(channel3, _) = third else { Issue.record("third should be ready"); return }
        #expect(channel3.gen == 2)
    }

    // MARK: - Step-5 no-op shapes (finding 16 a/b/c)

    @Test(
        "break-old teardown failures still resolve ready (finding 16 a/b/c)",
        arguments: [["-O cancel"], ["rm -f"], ["-O cancel", "rm -f"]]
    )
    func stepFiveTeardownFailuresStillReady(failing: [String]) async {
        // (a) `-O cancel` fails (master death / nothing to cancel),
        // (b) stale-socket `rm` fails (orphaned forward after restart),
        // (c) `-O cancel` rejected by the master — all degrade-never-wrong: the
        // new generation is already committed, so ready stands.
        let harness = Harness(failIf: { command in
            failing.contains { needle in
                if needle == "rm -f" {
                    return command.contains(needle) && command.contains("awesomux-bridge-")
                }
                return command.contains(needle)
            }
        })
        _ = await harness.preflight.attach(Self.request) // gen 1, no teardown yet
        let second = await harness.preflight.attach(Self.request)
        guard case .ready = second else {
            Issue.record("teardown failure must not demote a committed ready, got \(second)")
            return
        }
    }

    // MARK: - Single-flight cancel-and-restart

    @Test("a second attach while preparing cancels the first and releases its new resources")
    func secondAttachCancelsAndRestarts() async {
        let harness = Harness()
        await harness.gate.arm()

        let first = Task { await harness.preflight.attach(Self.request) }
        // Wait until the first attach is parked at its (gated) forward — its new
        // listener is bound by now.
        await harness.gate.awaitWaiting()

        // The second attach cancels the in-flight first; the gate is cancellation-
        // aware, so the first unblocks, observes cancellation, and rolls back.
        let second = Task { await harness.preflight.attach(Self.request) }

        let firstOutcome = await first.value
        let secondOutcome = await second.value

        #expect(firstOutcome == .cancelled)
        guard case .ready = secondOutcome else {
            Issue.record("restarted attach should be ready, got \(secondOutcome)")
            return
        }
        // The cancelled attach's new listener was shut down.
        #expect(await harness.timeline.events.contains("shutdown:/tmp/fake-listener-1.sock"))
        // Only the surviving attach committed a generation.
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 1)
    }

    // MARK: - Owner-only admission parse

    @Test(
        "owner-only admission accepts owner-only modes and rejects group/world access",
        arguments: [("600", true), ("700", true), ("640", false), ("660", false), ("666", false), ("", false), ("garbage", false)]
    )
    func admissionParse(mode: String, passes: Bool) {
        #expect(AmxBackend.bridgeAdmissionPassed(statOutput: mode.isEmpty ? "" : mode + "\n") == passes)
    }

    // MARK: - Helpers

    private static func execCommands(_ events: [String]) -> [String] {
        events.filter { $0.hasPrefix("exec:") }.map { String($0.dropFirst("exec:".count)) }
    }
}

// MARK: - Test doubles

private enum HarnessError: Error { case injected }

/// A plain mutable flag flipped between attaches. Only ever touched from the
/// test's own serialized flow (before/after an `await attach`), so a lock buys
/// nothing; `@unchecked Sendable` documents that the closure captures it.
private final class FailBox: @unchecked Sendable {
    var active = false
}

private actor TimelineLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor ListenerCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

/// A one-shot, cancellation-aware gate used only by the single-flight test to
/// park an attach at its forward step until the run's own cancellation unblocks
/// it — making cancel-and-restart deterministic without sleeps or yield races.
private actor AttachGate {
    private var armed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var released = false

    func arm() { armed = true }

    func waitOnceForForward(_ command: String) async {
        guard armed, command.contains("-O forward") else { return }
        armed = false
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                    return
                }
                waiter = continuation
                isWaiting = true
            }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func awaitWaiting() async {
        while !isWaiting { await Task.yield() }
    }

    private func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private struct Harness {
    let preflight: BridgeAttachPreflight
    let ledger: BridgeSocketLedger
    let timeline: TimelineLog
    let gate: AttachGate

    init(
        admissionMode: @escaping @Sendable () -> String = { "600" },
        failIf: @escaping @Sendable (String) -> Bool = { _ in false },
        listenerFailsOn: @escaping @Sendable (Int) -> Bool = { _ in false }
    ) {
        let timeline = TimelineLog()
        let ledger = BridgeSocketLedger()
        let gate = AttachGate()
        let counter = ListenerCounter()

        let exec: BridgeAttachPreflight.ExecChannel = { command, _ in
            await timeline.record("exec:\(command)")
            await gate.waitOnceForForward(command)
            if failIf(command) { throw HarnessError.injected }
            if command.contains("stat -c %a") {
                return Data((admissionMode() + "\n").utf8)
            }
            return Data()
        }
        let makeListener: BridgeAttachPreflight.MakeListener = { _, _ in
            let n = await counter.next()
            if listenerFailsOn(n) { throw HarnessError.injected }
            let path = "/tmp/fake-listener-\(n).sock"
            await timeline.record("bind:\(path)")
            return BridgeAttachPreflight.PreparedListener(socketPath: path) {
                await timeline.record("shutdown:\(path)")
            }
        }

        self.timeline = timeline
        self.ledger = ledger
        self.gate = gate
        self.preflight = BridgeAttachPreflight(
            ledger: ledger,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            execChannel: exec,
            makeListener: makeListener
        )
    }
}
