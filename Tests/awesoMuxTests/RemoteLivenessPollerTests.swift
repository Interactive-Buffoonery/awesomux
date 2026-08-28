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
}
