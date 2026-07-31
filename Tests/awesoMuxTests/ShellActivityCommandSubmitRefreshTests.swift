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

    @Test("Ctrl-C and Ctrl-U identify line resets from NSEvent")
    func controlLineResetsUseKeyAndModifierPath() {
        #expect(
            GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x08, modifiers: [.control], characters: "\u{3}")
            )
        )
        #expect(
            GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x20, modifiers: [.control], characters: "\u{15}")
            )
        )
    }

    @Test("Command-C/U and unmodified C/U are not line resets")
    func nonControlLineKeysDoNotReset() {
        #expect(
            !GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x08, modifiers: [.command], characters: "c")
            )
        )
        #expect(
            !GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x20, modifiers: [.command], characters: "u")
            )
        )
        #expect(
            !GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x08, modifiers: [], characters: "c")
            )
        )
        #expect(
            !GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(
                keyEvent(keyCode: 0x20, modifiers: [], characters: "u")
            )
        )
    }

    @Test("line reset clears stale capture and allows continued capture")
    func lineResetClearsStaleCaptureAndAllowsContinuedCapture() {
        let inputState = GhosttySurfaceInputState()

        for keyCode in [UInt16(0x08), UInt16(0x20)] {
            inputState.submittedSSHCommandBuffer = "ssh stale"
            inputState.submittedSSHCommandCaptureDisabled = true

            let event = keyEvent(keyCode: keyCode, modifiers: [.control], characters: "")
            if GhosttySurfaceNSView.isSubmittedSSHCommandLineReset(event) {
                inputState.resetSubmittedSSHCommandCapture()
            }
            inputState.submittedSSHCommandBuffer.append("ssh fresh")

            #expect(inputState.submittedSSHCommandBuffer == "ssh fresh")
            #expect(!inputState.submittedSSHCommandCaptureDisabled)
        }
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
