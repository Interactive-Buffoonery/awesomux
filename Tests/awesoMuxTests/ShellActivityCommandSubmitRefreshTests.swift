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
}
