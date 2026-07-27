import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("WorkspaceTitleCommit")
struct WorkspaceTitleCommitTests {
    /// A workspace title has no live terminal-supplied fallback (unlike a pane),
    /// so a blank commit cannot mean "reset" — it must leave the title alone.
    @Test("blank and whitespace-only input never renames")
    func blankInputNeverRenames() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "", current: "Old")
                == .noChange
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "   ", current: "Old")
                == .noChange
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "\t\n ", current: "Old")
                == .noChange
        )
    }

    /// Committing without editing must not write to the store — a redundant
    /// rename would churn persistence and any attention bookkeeping keyed on it.
    @Test("unchanged input does not rename")
    func unchangedInputDoesNotRename() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "Same", current: "Same")
                == .noChange
        )
        // Sanitizing is applied before comparison, so trailing whitespace is
        // still "unchanged" rather than a rename to an identical string.
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "Same  ", current: "Same")
                == .noChange
        )
    }

    /// The stored title is the sanitized form, not the raw keystrokes.
    @Test("changed input renames with the sanitized title")
    func changedInputRenamesWithSanitizedTitle() {
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "New name", current: "Old")
                == .rename("New name")
        )
        #expect(
            WorkspaceTitleCommit.resolveWorkspaceTitleCommit(input: "  Padded  ", current: "Old")
                == .rename(SessionStore.sanitizedTitle("  Padded  "))
        )
    }
}
