import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("DaemonReapGuard")
struct DaemonReapGuardTests {
    private static let id = TerminalSessionID(rawValue: "sess-1")!

    @Test(arguments: [
        (DaemonLifecycle.abandoned, 100 as Int32?, 1_000, 0, true),
        (.abandoned, 999, 1_000, 0, false),
        (.abandoned, 100, 2_000, 0, false),
        (.abandoned, nil, 1_000, 0, false),
        (.abandoned, 100, 1_000, 1, false),
        (.expired, 100, 1_000, 1, false),
        (.owned, 100, 1_000, 2, true),
        (.detachedRestorable, 100, 1_000, 1, true),
        (.owned, 999, 1_000, 1, false),
    ])
    func revalidatesBeforeReaping(lifecycle: DaemonLifecycle, pid: Int32?, created: Int, clients: Int, expected: Bool) {
        let target = DaemonReapGuard.Target(id: Self.id, pid: 100, createdEpoch: 1_000, lifecycle: lifecycle)
        let current = pid.map { LiveDaemon(id: Self.id, pid: $0, createdEpoch: created, clients: clients) }
        #expect(DaemonReapGuard.mayReap(target: target, current: current) == expected)
    }
}
