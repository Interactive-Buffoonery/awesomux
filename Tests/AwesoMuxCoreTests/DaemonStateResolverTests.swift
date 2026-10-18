import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("DaemonStateResolver")
struct DaemonStateResolverTests {
    private struct LifecycleCase: Sendable {
        var clients = 0
        var idle: Bool? = nil
        var owned = false
        var restorable = false
        var pinned = false
        var cap: Int? = nil
        var now = 1000
        let lifecycle: DaemonLifecycle
        var owner: String? = nil
        var reapable: Bool? = nil
    }

    @Test(arguments: [
        LifecycleCase(clients: 1, idle: false, owned: true, lifecycle: .owned, owner: "proj · zsh", reapable: true),
        LifecycleCase(idle: true, restorable: true, lifecycle: .detachedRestorable),
        LifecycleCase(lifecycle: .abandoned),
        LifecycleCase(clients: 1, lifecycle: .inUseElsewhere, reapable: false),
        LifecycleCase(idle: true, cap: 500, lifecycle: .expired),
        LifecycleCase(idle: true, pinned: true, cap: 500, lifecycle: .abandoned),
        LifecycleCase(idle: true, now: 99999, lifecycle: .abandoned),
        LifecycleCase(idle: false, cap: 500, lifecycle: .abandoned),
    ])
    private func resolvesLifecycle(scenario: LifecycleCase) throws {
        let sessionID = TerminalSessionID(rawValue: "11111111-1111-4111-8111-111111111111")!
        let rows = DaemonStateResolver.resolve(
            .init(
                live: [LiveDaemon(id: sessionID, pid: 1, createdEpoch: 0, clients: scenario.clients)],
                idleByID: scenario.idle.map { [sessionID: $0] } ?? [:],
                ownedByLivePane: scenario.owned ? [sessionID] : [], restorable: scenario.restorable ? [sessionID] : [],
                owners: scenario.owner.map { [sessionID: $0] } ?? [:], pinned: scenario.pinned ? [sessionID] : [],
                capThresholdSeconds: scenario.cap, now: scenario.now))
        let row = try #require(rows.first)
        #expect(row.lifecycle == scenario.lifecycle)
        #expect(row.owner == scenario.owner)
        if let idle = scenario.idle { #expect(row.activity == (idle ? .idle : .busy)) }
        if let reapable = scenario.reapable { #expect(row.isReapable == reapable) }
        if scenario.pinned { #expect(row.pinned) }
    }
}
