import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Remote liveness poller")
struct RemoteLivenessPollerTests {
    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    actor ProbeGate {
        private var commands: [String] = []
        private var firstStartedContinuation: CheckedContinuation<Void, Never>?
        private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

        func run(command: String) async -> RemoteForegroundLiveness? {
            commands.append(command)
            guard command == "first" else { return .idleShell }
            firstStartedContinuation?.resume()
            firstStartedContinuation = nil
            await withCheckedContinuation { firstReleaseContinuation = $0 }
            return .idleShell
        }

        func waitForFirstProbe() async {
            if commands.contains("first") { return }
            await withCheckedContinuation { firstStartedContinuation = $0 }
        }

        func releaseFirstProbe() {
            firstReleaseContinuation?.resume()
            firstReleaseContinuation = nil
        }

        func receivedCommands() -> [String] { commands }
    }

    @Test("duplicate pane probes share one active task")
    func duplicateProbesAreDeduplicated() async {
        let counter = Counter()
        let poller = RemoteLivenessPoller { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(30))
            return .idleShell
        }
        let key = RemoteLivenessPoller.Key(workspaceID: UUID(), paneID: UUID())

        async let first = poller.sample(key: key, command: "first")
        async let second = poller.sample(key: key, command: "second")
        #expect(await first == .idleShell)
        #expect(await second == .idleShell)
        #expect(await counter.value == 1)
    }

    @Test("cancelling a queued probe removes its concurrency waiter")
    func cancellingQueuedProbeRemovesWaiter() async {
        let gate = ProbeGate()
        let poller = RemoteLivenessPoller(maximumConcurrentProbes: 1) { command in
            await gate.run(command: command)
        }
        let workspaceID = UUID()
        let firstKey = RemoteLivenessPoller.Key(workspaceID: workspaceID, paneID: UUID())
        let cancelledKey = RemoteLivenessPoller.Key(workspaceID: workspaceID, paneID: UUID())
        let finalKey = RemoteLivenessPoller.Key(workspaceID: workspaceID, paneID: UUID())

        let first = Task { await poller.sample(key: firstKey, command: "first") }
        await gate.waitForFirstProbe()
        let cancelled = Task { await poller.sample(key: cancelledKey, command: "cancelled") }
        while !(await poller.cancel(key: cancelledKey)) {
            await Task.yield()
        }
        let final = Task { await poller.sample(key: finalKey, command: "final") }

        await gate.releaseFirstProbe()
        #expect(await first.value == .idleShell)
        #expect(await cancelled.value == nil)
        #expect(await final.value == .idleShell)
        #expect(await gate.receivedCommands() == ["first", "final"])
    }
}
