import AwesoMuxTestSupport
import Testing

@testable import awesoMux

/// The Resume control on a transcript tab is an `NSButton` with
/// `refusesFirstResponder = true` — the same focus-safety pattern as the tab
/// pill's close X (INT-562) — so it is unreachable with Full Keyboard Access
/// and switch control. Unlike Send to Agent, whose click only opens a
/// keyboard-operable composer, it fires a terminal-affecting action directly.
///
/// The menu item is the fix, and a SwiftUI `Commands` body cannot be
/// instantiated from a test, so its wiring is pinned as a source contract the
/// same way the destructive-action confirmations are.
@Suite("Agent transcript command surface")
struct AgentTranscriptCommandSurfaceTests {
    private static let path = "Sources/awesoMux/App/AwesoMuxApp.swift"

    @Test("the Workspace menu offers Resume Agent Session, bound and gated")
    func workspaceMenuOffersResumeAgentSession() throws {
        let source = try SourceContract.source(at: Self.path)

        #expect(source.contains("resumeSelectedTranscriptSession()"))
        #expect(
            source.contains("shortcut(KeyboardShortcutCatalog.resumeAgentSession)"),
            "the menu item must carry the catalog binding, or the chord is advertised but dead"
        )
        // Gated like its neighbours, NOT on the selected tab. Gating on the tab
        // meant the command was disabled most of the time, and a disabled
        // SwiftUI command does not consume its key equivalent — ⌃⌘R fell through
        // to libghostty, which echoed a CSI-u sequence into the user's shell.
        // Asserting the absence too, so the old shape cannot quietly return.
        #expect(
            source.contains(
                ".disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)"))
        #expect(
            !source.contains(".disabled(selectedSessionTranscriptTab == nil)"),
            "gating Resume on the selected tab leaks ⌃⌘R into the terminal"
        )
    }

    /// Same command, second surface. The palette entry is what makes it
    /// searchable; the menu is what makes it keyboard-navigable.
    @Test("the palette action is wired to the same command")
    func paletteActionIsWiredToTheSameCommand() throws {
        let source = try SourceContract.source(at: Self.path)
        #expect(source.contains("resumeAgentSession: resumeSelectedTranscriptSession"))
    }

    /// `announce` defaults to `.medium`, so deleting this argument is a silent
    /// revert: the code still compiles, still announces, and the announcement
    /// still loses to the terminal's own value-changed post for the text that
    /// was just staged. The user then hears the command read out with nothing
    /// saying it was staged rather than run — which is the whole point of never
    /// auto-submitting, and is only observable with VoiceOver actually on.
    ///
    /// A source contract because the announcement goes straight to
    /// `NSAccessibility.post` with no injectable seam, and the collision is
    /// with the OS, below anything a unit test can reach. Both routes are
    /// pinned: the send-bar button and the menu/palette command each announce
    /// separately, and either could regress alone.
    @Test("both resume-staged announcements outrank the terminal")
    func resumeStagedAnnouncementsArePostedAtHighPriority() throws {
        for path in [Self.path, "Sources/awesoMux/Views/DocumentPaneView.swift"] {
            let source = try SourceContract.source(at: path)
            guard let index = source.range(of: "Pasted into this transcript's terminal")?.upperBound
            else {
                Issue.record("\(path) no longer carries the staged-resume announcement")
                continue
            }
            // Wide enough to clear the `comment:` argument and the explanatory
            // block both call sites carry, narrow enough that it cannot reach
            // an unrelated `announce` further down the file.
            if !source[index...].prefix(800).contains("priority: .high") {
                Issue.record(
                    "\(path) stages a resume without an explicit .high priority, so the confirmation loses to the terminal's own value-changed announcement"
                )
            }
        }
    }
}
