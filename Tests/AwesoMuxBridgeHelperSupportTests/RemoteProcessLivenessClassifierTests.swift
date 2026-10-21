import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct RemoteProcessLivenessClassifierTests {

    @Test(arguments: [
        ProcessTableSnapshot(processes: [], markerSeenButUnreadable: true),
        .init(processes: [
            process(10, foregroundGroup: 20, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, foregroundGroup: 20, command: "bash", marked: true),
        ]),
        .init(processes: [
            process(10, terminal: 0, foregroundGroup: -1, command: "zsh", marked: true)
        ]),
    ])
    func incompleteProcessEvidenceIsIndeterminate(snapshot: ProcessTableSnapshot) {
        let report = RemoteProcessLivenessClassifier.classify(snapshot)
        #expect(report.state == .indeterminate)
    }

    private static func process(
        _ pid: Int32,
        parent: Int32 = 1,
        group: Int32 = 10,
        session: Int32 = 10,
        terminal: Int64 = 34817,
        foregroundGroup: Int32 = 10,
        state: Character = "S",
        command: String,
        marked: Bool
    ) -> ProcessSnapshot {
        .init(
            pid: pid,
            parentPID: parent,
            processGroupID: group,
            processSessionID: session,
            controllingTerminal: terminal,
            foregroundProcessGroupID: foregroundGroup,
            state: state,
            command: command,
            startTime: UInt64(pid),
            hasSessionMarker: marked
        )
    }
}
