import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct RemoteProcessLivenessClassifierTests {

    @Test func unreadableMatchingEvidenceIsIndeterminate() {
        let report = RemoteProcessLivenessClassifier.classify(
            .init(processes: [], markerSeenButUnreadable: true)
        )
        #expect(report.state == .indeterminate)
    }

    @Test func nestedForegroundShellIsConservative() {
        let report = classify([
            process(10, foregroundGroup: 20, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, foregroundGroup: 20, command: "bash", marked: true),
        ])
        #expect(report.state == .indeterminate)
    }

    @Test func missingControllingTerminalIsConservative() {
        let report = classify([
            process(10, terminal: 0, foregroundGroup: -1, command: "zsh", marked: true)
        ])
        #expect(report.state == .indeterminate)
    }

    private func classify(_ processes: [ProcessSnapshot]) -> RemoteForegroundLivenessReport {
        RemoteProcessLivenessClassifier.classify(.init(processes: processes))
    }

    private func process(
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
