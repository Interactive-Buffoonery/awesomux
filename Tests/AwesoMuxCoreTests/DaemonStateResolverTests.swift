import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("DaemonStateResolver")
struct DaemonStateResolverTests {
    private func id(_ s: String) -> TerminalSessionID { TerminalSessionID(rawValue: s)! }
    private let a = "11111111-1111-4111-8111-111111111111"

    private func daemon(_ raw: String, pid: Int32 = 1, created: Int = 0, clients: Int = 0) -> LiveDaemon {
        LiveDaemon(id: id(raw), pid: pid, createdEpoch: created, clients: clients)
    }

    private func resolve(
        live: [LiveDaemon], idle: [TerminalSessionID: Bool] = [:],
        owned: Set<TerminalSessionID> = [], restorable: Set<TerminalSessionID> = [],
        owners: [TerminalSessionID: String] = [:], pinned: Set<TerminalSessionID> = [],
        cap: Int? = nil, now: Int = 1000
    ) -> [DaemonRow] {
        DaemonStateResolver.resolve(.init(
            live: live, idleByID: idle, ownedByLivePane: owned, restorable: restorable,
            owners: owners, pinned: pinned, capThresholdSeconds: cap, now: now
        ))
    }

    @Test("owned daemon (live pane) classified owned with owner label + activity")
    func owned() {
        let rows = resolve(live: [daemon(a, clients: 1)], idle: [id(a): false],
                           owned: [id(a)], owners: [id(a): "proj · zsh"])
        #expect(rows.first?.lifecycle == .owned)
        #expect(rows.first?.activity == .busy)
        #expect(rows.first?.owner == "proj · zsh")
        #expect(rows.first?.isReapable == true)
    }

    @Test("restorable-only id classified detachedRestorable")
    func detached() {
        let rows = resolve(live: [daemon(a)], idle: [id(a): true], restorable: [id(a)])
        #expect(rows.first?.lifecycle == .detachedRestorable)
        #expect(rows.first?.activity == .idle)
    }

    @Test("unreachable clients==0 orphan classified abandoned")
    func abandoned() {
        let rows = resolve(live: [daemon(a, clients: 0)])
        #expect(rows.first?.lifecycle == .abandoned)
        #expect(rows.first?.owner == nil)
    }

    @Test("clients>0 but unreachable classified inUseElsewhere and non-reapable")
    func inUseElsewhere() {
        let rows = resolve(live: [daemon(a, clients: 1)])
        #expect(rows.first?.lifecycle == .inUseElsewhere)
        #expect(rows.first?.isReapable == false)
    }

    @Test("abandoned + idle + over cap + unpinned escalates to expired")
    func expired() {
        let rows = resolve(live: [daemon(a, created: 0, clients: 0)], idle: [id(a): true],
                           cap: 500, now: 1000)   // age 1000 >= 500
        #expect(rows.first?.lifecycle == .expired)
    }

    @Test("pin prevents expired escalation (stays abandoned, pinned=true)")
    func pinnedNotExpired() {
        let rows = resolve(live: [daemon(a, created: 0, clients: 0)], idle: [id(a): true],
                           pinned: [id(a)], cap: 500, now: 1000)
        #expect(rows.first?.lifecycle == .abandoned)
        #expect(rows.first?.pinned == true)
    }

    @Test("cap off: old idle orphan stays abandoned, never expired")
    func capOff() {
        let rows = resolve(live: [daemon(a, created: 0, clients: 0)], idle: [id(a): true],
                           cap: nil, now: 99_999)
        #expect(rows.first?.lifecycle == .abandoned)
    }

    @Test("busy orphan under cap does not expire (cap requires idle)")
    func busyNotExpired() {
        let rows = resolve(live: [daemon(a, created: 0, clients: 0)], idle: [id(a): false],
                           cap: 500, now: 1000)
        #expect(rows.first?.lifecycle == .abandoned)
    }
}
