import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("SessionManagerSnapshotDiffer")
struct SessionManagerSnapshotDifferTests {
    private func id(_ s: String) -> TerminalSessionID { TerminalSessionID(rawValue: s)! }
    private let a = "11111111-1111-4111-8111-111111111111"

    private func row(_ raw: String, _ life: DaemonLifecycle, _ act: DaemonActivity,
                     owner: String? = "proj · zsh") -> DaemonRow {
        DaemonRow(id: id(raw), pid: 1, createdEpoch: 0, clients: 0,
                  lifecycle: life, activity: act, pinned: false, owner: owner)
    }

    @Test("idle→busy emits an activityChanged announcement")
    func activity() {
        let changes = SessionManagerSnapshotDiffer.changes(
            from: [row(a, .owned, .idle)], to: [row(a, .owned, .busy)])
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .activityChanged)
        #expect(changes.first?.spoken.contains("busy") == true)
    }

    @Test("owned→abandoned emits a lifecycleChanged announcement")
    func lifecycle() {
        let changes = SessionManagerSnapshotDiffer.changes(
            from: [row(a, .owned, .idle)], to: [row(a, .abandoned, .idle, owner: nil)])
        #expect(changes.first?.kind == .lifecycleChanged)
        #expect(changes.first?.spoken.contains("abandoned") == true)
    }

    @Test("simultaneous lifecycle+activity change emits only lifecycleChanged")
    func precedence() {
        let changes = SessionManagerSnapshotDiffer.changes(
            from: [row(a, .owned, .idle)],
            to:   [row(a, .abandoned, .busy, owner: nil)])
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .lifecycleChanged)
    }

    @Test("no change emits nothing")
    func stable() {
        let r = [row(a, .owned, .busy)]
        #expect(SessionManagerSnapshotDiffer.changes(from: r, to: r).isEmpty)
    }

    @Test("appeared and disappeared are reported")
    func appearDisappear() {
        let appeared = SessionManagerSnapshotDiffer.changes(from: [], to: [row(a, .abandoned, .idle, owner: nil)])
        #expect(appeared.first?.kind == .appeared)
        let gone = SessionManagerSnapshotDiffer.changes(from: [row(a, .abandoned, .idle, owner: nil)], to: [])
        #expect(gone.first?.kind == .disappeared)
    }
}
