import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct RemoteProcessLivenessClassifierTests {
    @Test func noMatchingMarkerIsGone() {
        #expect(classify([]).state == .gone)
    }

    @Test func unreadableMatchingEvidenceIsIndeterminate() {
        let report = RemoteProcessLivenessClassifier.classify(
            .init(processes: [], markerSeenButUnreadable: true)
        )
        #expect(report.state == .indeterminate)
    }

    @Test(arguments: [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "csh", "tcsh", "nu", "pwsh", "xonsh", "elvish",
    ])
    func idleSupportedShell(command: String) {
        let report = classify([process(10, command: command, marked: true)])
        #expect(report == .init(state: .idleShell, comm: command, hasChildren: false))
    }

    @Test func foregroundCommand() {
        let report = classify([
            process(10, foregroundGroup: 20, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, foregroundGroup: 20, command: "vim", marked: true),
        ])
        #expect(report.state == .liveCommand)
        #expect(report.comm == "vim")
    }

    @Test func backgroundJobMakesShellBusy() {
        let report = classify([
            process(10, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, command: "sleep", marked: true),
        ])
        #expect(report == .init(state: .busyShell, comm: "zsh", hasChildren: true))
    }

    @Test func zombieChildDoesNotMakeShellBusy() {
        let report = classify([
            process(10, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, state: "Z", command: "sleep", marked: true),
        ])
        #expect(report.state == .idleShell)
    }

    @Test func pipelineSurvivesMissingOriginalGroupLeader() {
        let report = classify([
            process(10, foregroundGroup: 20, command: "zsh", marked: true),
            process(21, parent: 10, group: 20, foregroundGroup: 20, command: "grep", marked: true),
        ])
        #expect(report.state == .liveCommand)
        #expect(report.comm == "grep")
    }

    @Test func inheritedMarkersStillChooseOuterShell() {
        let report = classify([
            process(10, foregroundGroup: 20, command: "zsh", marked: true),
            process(20, parent: 10, group: 20, foregroundGroup: 20, command: "make", marked: true),
            process(21, parent: 20, group: 20, foregroundGroup: 20, command: "cc", marked: true),
        ])
        #expect(report.state == .liveCommand)
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

    @Test func contradictoryOuterShellsAreConservative() {
        let report = classify([
            process(10, command: "zsh", marked: true),
            process(30, parent: 1, command: "bash", marked: true),
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
