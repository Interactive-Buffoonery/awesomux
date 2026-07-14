import Testing
@testable import AwesoMuxCore

@Suite("ForegroundProcessLiveness.classify")
struct ForegroundProcessLivenessTests {
    @Test("exited process is exited regardless of foreground")
    func exited() {
        #expect(ForegroundProcessLiveness.classify(processExited: true, foregroundComm: "zsh", foregroundHasChildren: false) == .exited)
        #expect(ForegroundProcessLiveness.classify(processExited: true, foregroundComm: nil, foregroundHasChildren: nil) == .exited)
    }

    @Test("unresolved foreground comm on a live surface is indeterminate")
    func indeterminate() {
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: nil, foregroundHasChildren: nil) == .indeterminate)
    }

    @Test("non-shell foreground is a live command")
    func liveCommand() {
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: "vim", foregroundHasChildren: false) == .liveCommand)
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: "node", foregroundHasChildren: nil as Bool?) == .liveCommand)
    }

    @Test("idle shell with no children")
    func idleShell() {
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: "-zsh", foregroundHasChildren: false) == .idleShell)
    }

    @Test("shell with background children is busy (the npm-run-dev & hole)")
    func busyShell() {
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: "zsh", foregroundHasChildren: true) == .busyShell)
    }

    @Test("shell foreground with unresolved child count is indeterminate, not idle")
    func shellUnknownChildren() {
        #expect(ForegroundProcessLiveness.classify(processExited: false, foregroundComm: "bash", foregroundHasChildren: nil as Bool?) == .indeterminate)
    }

    @Test("bridged shell distinguishes idle from child work")
    func bridgedShell() {
        #expect(ForegroundProcessLiveness.classifyBridged(rootComm: "-zsh", rootHasChildren: false) == .bridged)
        #expect(ForegroundProcessLiveness.classifyBridged(rootComm: "-zsh", rootHasChildren: true) == .bridgedBusy)
        #expect(ForegroundProcessLiveness.classifyBridged(rootComm: "sleep", rootHasChildren: false) == .bridgedBusy)
    }
}

@Suite("AgentLivenessPolicy.shouldResetAgentChrome (INT-552)")
struct AgentLivenessPolicyTests {
    @Test(
        "only an idle shell under an agent-tagged pane resets agent chrome",
        arguments: [AgentKind.claudeCode, .codex, .openCode, .pi, .grok]
    )
    func idleShellResetsEveryAgentKind(kind: AgentKind) {
        #expect(AgentLivenessPolicy.shouldResetAgentChrome(agentKind: kind, liveness: .idleShell))
    }

    @Test("a shell pane never resets, even over an idle shell")
    func shellKindNeverResets() {
        for liveness: ForegroundProcessLiveness in [
            .unsampled, .bridged, .bridgedBusy, .exited, .idleShell, .busyShell, .liveCommand, .indeterminate
        ] {
            #expect(!AgentLivenessPolicy.shouldResetAgentChrome(agentKind: .shell, liveness: liveness))
        }
    }

    @Test(
        "non-idle-shell liveness never resets an agent pane",
        arguments: [
            ForegroundProcessLiveness.unsampled, .bridged, .bridgedBusy, .exited,
            .busyShell, .liveCommand, .indeterminate
        ]
    )
    func onlyIdleShellIsPositiveEvidence(liveness: ForegroundProcessLiveness) {
        #expect(!AgentLivenessPolicy.shouldResetAgentChrome(agentKind: .openCode, liveness: liveness))
    }
}
