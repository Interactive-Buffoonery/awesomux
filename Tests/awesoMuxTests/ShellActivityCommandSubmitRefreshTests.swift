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

    @Test("Ctrl-C clears and re-arms capture")
    func controlCClearsAndRearmsCapture() {
        let inputState = GhosttySurfaceInputState()
        inputState.submittedSSHCommandBuffer = "ssh stale"
        inputState.submittedSSHCommandCaptureDisabled = true

        #expect(
            GhosttySurfaceNSView.applySubmittedSSHCommandLineControl(
                keyEvent(keyCode: 0x2A, modifiers: [.control], characters: "\u{3}"),
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

    @Test("Command-C/U and unmodified C do not change capture")
    func nonControlLineKeysDoNotChangeCapture() {
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
