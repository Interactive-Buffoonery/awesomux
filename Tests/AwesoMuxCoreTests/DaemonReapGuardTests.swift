import Testing
@testable import AwesoMuxCore

@Suite("DaemonReapGuard")
struct DaemonReapGuardTests {
    private static let id = TerminalSessionID(rawValue: "sess-1")!

    private func target(
        pid: Int32 = 100, createdEpoch: Int = 1_000, lifecycle: DaemonLifecycle = .abandoned
    ) -> DaemonReapGuard.Target {
        DaemonReapGuard.Target(
            id: Self.id,
            pid: pid, createdEpoch: createdEpoch, lifecycle: lifecycle
        )
    }

    private func live(pid: Int32 = 100, createdEpoch: Int = 1_000, clients: Int = 0) -> LiveDaemon {
        LiveDaemon(id: Self.id, pid: pid, createdEpoch: createdEpoch, clients: clients)
    }

    @Test("identity match (orphan, no clients) proceeds")
    func identityMatchProceeds() {
        #expect(DaemonReapGuard.mayReap(target: target(), current: live()) == true)
    }

    @Test("pid mismatch aborts (recycled id)")
    func pidMismatchAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(pid: 100), current: live(pid: 999)) == false)
    }

    @Test("createdEpoch mismatch aborts (restarted id)")
    func createdEpochMismatchAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(createdEpoch: 1_000), current: live(createdEpoch: 2_000)) == false)
    }

    @Test("current == nil aborts (gone or unlistable)")
    func currentNilAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(), current: nil) == false)
    }

    @Test("abandoned with clients > 0 aborts (reattached since user saw it)")
    func abandonedReattachedAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(lifecycle: .abandoned), current: live(clients: 1)) == false)
    }

    @Test("expired with clients > 0 aborts (reattached since user saw it)")
    func expiredReattachedAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(lifecycle: .expired), current: live(clients: 1)) == false)
    }

    @Test("owned with clients > 0 proceeds (intentional live kill, identity-checked)")
    func ownedWithClientsProceeds() {
        #expect(DaemonReapGuard.mayReap(target: target(lifecycle: .owned), current: live(clients: 2)) == true)
    }

    @Test("detachedRestorable with clients > 0 proceeds (intentional live kill)")
    func detachedRestorableWithClientsProceeds() {
        #expect(DaemonReapGuard.mayReap(target: target(lifecycle: .detachedRestorable), current: live(clients: 1)) == true)
    }

    @Test("owned still aborts on pid mismatch (never kill a recycled id)")
    func ownedPidMismatchAborts() {
        #expect(DaemonReapGuard.mayReap(target: target(pid: 100, lifecycle: .owned), current: live(pid: 999, clients: 1)) == false)
    }
}
