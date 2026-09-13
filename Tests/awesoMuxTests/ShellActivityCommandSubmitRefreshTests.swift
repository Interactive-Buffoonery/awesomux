import AppKit
import AwesoMuxCore
import Foundation
import GhosttyKit
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

    @Test("command and unmodified keys do not change capture")
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
        #expect(inputState.submittedSSHCommandBuffer == "ssh devbox")
        #expect(!inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("line editing invalidates capture instead of resetting identity from stale text")
    func editedSSHLineDoesNotResetAgentIdentity() {
        let (store, session, pane, view) = agentFixture()
        func input(keyCode: UInt16, text: String?, submit: Bool = false) {
            view.observeSubmittedSSHCommandInput(
                action: GHOSTTY_ACTION_PRESS,
                event: keyEvent(keyCode: keyCode, modifiers: [], characters: text ?? ""),
                text: text, handled: true, isCommandSubmit: submit,
                submittedAtObservedShellPrompt: true
            )
        }
        input(keyCode: 0, text: "ssh host")
        input(keyCode: 115, text: nil)
        input(keyCode: 0, text: "claude ")
        input(keyCode: 36, text: "\r", submit: true)
        #expect(store.session(id: session.id)?.layout.pane(id: pane.id)?.agentKind == .claudeCode)
        #expect(!view.inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("repeated input does not replay an erased SSH command")
    func repeatedInputDoesNotReplayAnErasedSSHCommand() {
        let (store, session, pane, view) = agentFixture()
        func input(
            action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS,
            keyCode: UInt16,
            text: String?,
            submit: Bool = false
        ) {
            view.observeSubmittedSSHCommandInput(
                action: action,
                event: keyEvent(keyCode: keyCode, modifiers: [], characters: text ?? ""),
                text: text,
                handled: true,
                isCommandSubmit: submit,
                submittedAtObservedShellPrompt: true
            )
        }

        input(keyCode: 0, text: "ssh host")
        input(keyCode: 51, text: nil)
        for _ in 0..<7 {
            input(action: GHOSTTY_ACTION_REPEAT, keyCode: 51, text: nil)
        }
        input(keyCode: 0, text: "claude")
        input(keyCode: 36, text: "\r", submit: true)

        let updatedPane = store.session(id: session.id)?.layout.pane(id: pane.id)
        #expect(updatedPane?.agentKind == .claudeCode)
        #expect(updatedPane?.pendingRemoteSSHTarget == nil)
        #expect(!view.inputState.submittedSSHCommandCaptureDisabled)

        input(action: GHOSTTY_ACTION_REPEAT, keyCode: 36, text: "\r", submit: false)
        #expect(store.session(id: session.id)?.layout.pane(id: pane.id)?.agentKind == .claudeCode)
        #expect(store.session(id: session.id)?.layout.pane(id: pane.id)?.pendingRemoteSSHTarget == nil)
        #expect(view.inputState.submittedSSHCommandCaptureDisabled)

        input(keyCode: 36, text: "\r", submit: true)
        #expect(!view.inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("held Ctrl-C keeps SSH capture armed")
    func repeatedControlCKeepsNextSSHCommandCaptured() {
        let (store, session, pane, view) = agentFixture()
        func input(
            action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags = [],
            text: String?,
            submit: Bool = false
        ) {
            view.observeSubmittedSSHCommandInput(
                action: action,
                event: keyEvent(keyCode: keyCode, modifiers: modifiers, characters: text ?? ""),
                text: text,
                handled: true,
                isCommandSubmit: submit,
                submittedAtObservedShellPrompt: true
            )
        }

        input(keyCode: 0x08, modifiers: [.control], text: "\u{3}")
        input(action: GHOSTTY_ACTION_REPEAT, keyCode: 0x08, modifiers: [.control], text: "\u{3}")
        input(keyCode: 0, text: "ssh host")
        input(keyCode: 36, text: "\r", submit: true)

        let updatedPane = store.session(id: session.id)?.layout.pane(id: pane.id)
        #expect(updatedPane?.agentKind == .shell)
        #expect(updatedPane?.pendingRemoteSSHTarget == "host")
    }

    @Test(
        "navigation and readline controls invalidate capture",
        arguments: [
            (UInt16(123), NSEvent.ModifierFlags(), ""),
            (UInt16(126), NSEvent.ModifierFlags(), ""),
            (UInt16(48), NSEvent.ModifierFlags(), "\t"),
            (UInt16(0), NSEvent.ModifierFlags.control, "\u{1}"),
            (UInt16(27), NSEvent.ModifierFlags([.control, .shift]), "\u{1f}"),
            (UInt16(11), NSEvent.ModifierFlags.option, "b"),
        ])
    func unmodeledEditingDisablesCapture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, text: String) {
        let inputState = GhosttySurfaceInputState()
        inputState.submittedSSHCommandBuffer = "ssh host"
        #expect(
            GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: keyCode, modifiers: modifiers, characters: text), to: inputState
            ))
        #expect(inputState.submittedSSHCommandBuffer.isEmpty)
        #expect(inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("IME composition prevents a later SSH-shaped suffix from resetting identity")
    func composedPrefixInvalidatesCapture() {
        let (store, session, pane, view) = agentFixture()
        view.setMarkedText("prefix ", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange())
        view.unmarkText()
        for (keyCode, text, submit) in [(UInt16(0), "ssh host", false), (UInt16(36), "\r", true)] {
            view.observeSubmittedSSHCommandInput(
                action: GHOSTTY_ACTION_PRESS,
                event: keyEvent(keyCode: keyCode, modifiers: [], characters: text),
                text: text, handled: true, isCommandSubmit: submit,
                submittedAtObservedShellPrompt: true
            )
        }
        #expect(store.session(id: session.id)?.layout.pane(id: pane.id)?.agentKind == .claudeCode)
        #expect(!view.inputState.submittedSSHCommandCaptureDisabled)
    }

    @Test("accepted paste invalidates capture even without string clipboard content")
    func acceptedNonStringPasteInvalidatesCapture() {
        let (_, _, _, view) = agentFixture()
        view.inputState.submittedSSHCommandBuffer = "ssh host"
        view.observeBindingAction("paste_from_clipboard", accepted: false, hasContent: false)
        #expect(view.inputState.submittedSSHCommandBuffer == "ssh host")
        view.observeBindingAction("copy_to_clipboard", accepted: true, hasContent: true)
        #expect(view.inputState.submittedSSHCommandBuffer == "ssh host")
        view.observeBindingAction("paste_from_clipboard", accepted: true, hasContent: false)
        #expect(view.inputState.submittedSSHCommandBuffer.isEmpty)
        #expect(view.inputState.submittedSSHCommandCaptureDisabled)
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
