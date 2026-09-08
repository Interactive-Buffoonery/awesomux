import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Shell activity command-submit refresh")
struct ShellActivityCommandSubmitRefreshTests {
    @Test("post-submit refreshes cover delayed prompt-marker flips and debounce")
    func postSubmitRefreshesCoverDelayedPromptMarkerFlipsAndDebounce() {
        let delays = GhosttyRuntime.shellActivityCommandSubmitRefreshDelays

        #expect(delays.first == 0.05)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
        #expect(
            (delays.last ?? 0) >= SessionStore.shellActivityBusyDebounceInterval * 2
        )
    }

    @Test("command-finished refreshes cover idle debounce")
    func commandFinishedRefreshesCoverIdleDebounce() {
        let delays = GhosttyRuntime.shellActivityCommandFinishedRefreshDelays

        #expect(zip(delays, delays.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
        #expect(
            (delays.last ?? 0) >= SessionStore.shellActivityIdleDebounceInterval
        )
    }

    @Test("command-finished latch overrides busy prompt marker")
    func commandFinishedLatchOverridesBusyPromptMarker() {
        #expect(
            GhosttySurfaceNSView.resolvedShellActivityBusy(
                promptMarkerIsAwayFromPrompt: true,
                commandFinishedIdleLatched: true
            ) == false
        )
    }

    @Test("cleared command-finished latch uses prompt marker")
    func expiredOrClearedLatchUsesPromptMarker() {
        #expect(
            GhosttySurfaceNSView.resolvedShellActivityBusy(
                promptMarkerIsAwayFromPrompt: true,
                commandFinishedIdleLatched: false
            ) == true
        )
        #expect(
            GhosttySurfaceNSView.resolvedShellActivityBusy(
                promptMarkerIsAwayFromPrompt: false,
                commandFinishedIdleLatched: false
            ) == false
        )
    }

    @Test("ssh command capture only keeps possible ssh prefixes")
    func sshCommandCaptureOnlyKeepsPossibleSSHPrefixes() {
        #expect(GhosttySurfaceNSView.isPossibleSubmittedSSHCommandPrefix(" s"))
        #expect(GhosttySurfaceNSView.isPossibleSubmittedSSHCommandPrefix(" ssh devbox"))
        #expect(!GhosttySurfaceNSView.isPossibleSubmittedSSHCommandPrefix("ssh-keygen"))
        #expect(!GhosttySurfaceNSView.isPossibleSubmittedSSHCommandPrefix("echo ssh devbox"))
    }

    @Test("Return and keypad Enter both submit captured commands")
    func returnKeysSubmitCapturedCommands() {
        #expect(
            GhosttySurfaceNSView.isCommandSubmitKey(
                keyEvent(keyCode: 0x24, modifiers: [], characters: "\r"),
                text: "\r"
            ))
        #expect(
            GhosttySurfaceNSView.isCommandSubmitKey(
                keyEvent(keyCode: 0x4C, modifiers: [.numericPad], characters: "\r"),
                text: "\r"
            ))
    }

    @Test("only SSH submitted at a shell prompt clears stale agent identity")
    func staleAgentResetRequiresSSHAtShellPrompt() {
        #expect(
            GhosttySurfaceNSView.shouldResetAgentIdentityForSubmittedSSH(
                command: "ssh devbox",
                agentKind: .claudeCode,
                submittedAtObservedShellPrompt: true
            ))
        #expect(
            !GhosttySurfaceNSView.shouldResetAgentIdentityForSubmittedSSH(
                command: "ssh devbox",
                agentKind: .shell,
                submittedAtObservedShellPrompt: true
            ))
        #expect(
            !GhosttySurfaceNSView.shouldResetAgentIdentityForSubmittedSSH(
                command: "ssh devbox",
                agentKind: .claudeCode,
                submittedAtObservedShellPrompt: false
            ))
        #expect(
            !GhosttySurfaceNSView.shouldResetAgentIdentityForSubmittedSSH(
                command: "echo ssh devbox",
                agentKind: .claudeCode,
                submittedAtObservedShellPrompt: true
            ))
        #expect(
            GhosttySurfaceNSView.shouldResetAgentIdentityForSubmittedSSH(
                command: "ssh -o ProxyCommand=helper devbox",
                agentKind: .claudeCode,
                submittedAtObservedShellPrompt: true
            ))
    }

    @Test("SSH submitted at a shell prompt resets the pane before tracking remote work")
    func submittedSSHResetsStaleAgentIdentity() throws {
        let (store, session, pane, view) = agentFixture()
        view.terminalEventState.hasObservedAgentActivity = true

        view.recordSubmittedCommand(
            "ssh devbox",
            submittedAtObservedShellPrompt: true
        )
        store.updatePane(
            sessionID: session.id,
            paneID: pane.id,
            title: "alice@example-remote: ~"
        )

        let updatedPane = try #require(store.session(id: session.id)?.layout.pane(id: pane.id))
        #expect(updatedPane.agentKind == .shell)
        #expect(updatedPane.agentExecutionState == .idle)
        #expect(updatedPane.remoteSSHTarget == "devbox")
        #expect(updatedPane.remoteHost == "example-remote")
        #expect(!view.terminalEventState.hasObservedAgentActivity)
    }

    @Test("SSH outside a proven shell prompt does not reset agent identity")
    func submittedSSHOutsideShellPromptKeepsAgentIdentity() throws {
        let (store, session, pane, view) = agentFixture()

        view.recordSubmittedCommand(
            "ssh devbox",
            submittedAtObservedShellPrompt: false
        )

        let updatedPane = try #require(store.session(id: session.id)?.layout.pane(id: pane.id))
        #expect(updatedPane.agentKind == .claudeCode)
        #expect(updatedPane.pendingRemoteSSHTarget == "devbox")
    }

    private func agentFixture() -> (
        SessionStore,
        TerminalSession,
        TerminalPane,
        GhosttySurfaceNSView
    ) {
        let pane = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "awesoMux", sessions: [session])])
        let view = GhosttyRuntime().surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .sessionStart
            ))
        return (store, session, pane, view)
    }

    @Test("Ctrl-C clears and re-arms capture")
    func controlCClearsAndRearmsCapture() {
        let inputState = GhosttySurfaceInputState()
        inputState.submittedSSHCommandBuffer = "ssh stale"
        inputState.submittedSSHCommandCaptureDisabled = true

        #expect(
            GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x08, modifiers: [.control], characters: "\u{3}"),
                to: inputState
            )
        )
        #expect(inputState.submittedSSHCommandBuffer.isEmpty)
        #expect(!inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("Ctrl-U clears and disables capture until submit")
    func controlUClearsAndDisablesCapture() {
        let inputState = GhosttySurfaceInputState()
        inputState.submittedSSHCommandBuffer = "ssh stale"

        #expect(
            GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x20, modifiers: [.control], characters: "\u{15}"),
                to: inputState
            )
        )
        #expect(inputState.submittedSSHCommandBuffer.isEmpty)
        #expect(inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("unrelated command, control, and unmodified keys do not change capture")
    func unrelatedKeysDoNotChangeCapture() {
        let inputState = GhosttySurfaceInputState()
        inputState.submittedSSHCommandBuffer = "ssh devbox"

        #expect(
            !GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x08, modifiers: [.command], characters: "c"),
                to: inputState
            )
        )
        #expect(
            !GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x20, modifiers: [.command], characters: "u"),
                to: inputState
            )
        )
        #expect(
            !GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x08, modifiers: [], characters: "c"),
                to: inputState
            )
        )
        #expect(
            !GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x00, modifiers: [.control], characters: "\u{1}"),
                to: inputState
            )
        )
        #expect(inputState.submittedSSHCommandBuffer == "ssh devbox")
        #expect(!inputState.submittedSSHCommandCaptureDisabled)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
