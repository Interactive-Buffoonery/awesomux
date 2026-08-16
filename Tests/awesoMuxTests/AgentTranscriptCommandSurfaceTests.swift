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
        #expect(source.contains(".disabled(selectedSessionTranscriptTab == nil)"))
    }

    /// Same command, second surface. The palette entry is what makes it
    /// searchable; the menu is what makes it keyboard-navigable.
    @Test("the palette action is wired to the same command")
    func paletteActionIsWiredToTheSameCommand() throws {
        let source = try SourceContract.source(at: Self.path)
        #expect(source.contains("resumeAgentSession: resumeSelectedTranscriptSession"))
    }
}
