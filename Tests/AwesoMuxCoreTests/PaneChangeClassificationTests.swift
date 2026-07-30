import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore

/// Issue #311: `SessionStore.updatePane` publishes `groups` for a durable change
/// and routes a chrome-text-only change to the live-title channel instead. That
/// split used to be two hand-maintained field lists — the reducer's early-out and
/// the facade's publish gate, exact complements of each other. A field added to
/// the reducer's list and forgotten in the facade's would have been classified
/// display-only and landed silently, freezing every consumer not on the live-title
/// channel: the precise failure #311 exists to fix.
///
/// `PaneLayoutReducer.paneChangeKind` is now the single list both decisions read.
/// These tests pin what it classifies, and the last one is the structural check —
/// it fails if `updatePane` learns to move a field the classifier does not compare.
@Suite("Pane change classification (#311)")
struct PaneChangeClassificationTests {

    private static let reducerPath = "Sources/AwesoMuxCore/Stores/PaneLayoutReducer.swift"

    private static func basePane() -> TerminalPane {
        TerminalPane(
            title: "pane",
            workingDirectory: "/tmp",
            remoteHost: "build-box",
            remoteSSHTarget: "build",
            pendingRemoteSSHTarget: "queued",
            remoteWorkingDirectory: "/srv",
            liveTerminalTitle: "pane",
            progressReport: TerminalProgressReport(state: .set, progress: 10),
            executionPlan: .local
        )
    }

    // MARK: - Durable fields

    /// Every field `updatePane` can move that carries runtime behaviour. Both
    /// operands come from ONE base pane with a single field mutated, so the
    /// verdict can only be that field's doing — building two panes from a factory
    /// would compare fresh `id`s as well and stay green with the field deleted.
    @Test("each durable field on its own classifies as durable")
    func durableFieldsClassifyAsDurable() {
        let mutations: [(field: String, mutate: (inout TerminalPane) -> Void)] = [
            ("workingDirectory", { $0.workingDirectory = "/var" }),
            ("remoteHost", { $0.remoteHost = "other-box" }),
            ("remoteSSHTarget", { $0.remoteSSHTarget = "other" }),
            ("hasConsumedManagedSSHWorkspaceOffer", { $0.hasConsumedManagedSSHWorkspaceOffer = true }),
            ("pendingRemoteSSHTarget", { $0.pendingRemoteSSHTarget = nil }),
            ("remoteWorkingDirectory", { $0.remoteWorkingDirectory = "/srv/other" }),
            ("remoteConnectionHealth", { $0.remoteConnectionHealth = .possiblyStale }),
            ("progressReport", { $0.progressReport = nil }),
        ]

        let old = Self.basePane()
        for mutation in mutations {
            var new = old
            mutation.mutate(&new)
            #expect(
                PaneLayoutReducer.paneChangeKind(from: old, to: new) == .durable,
                """
                Moving `\(mutation.field)` alone must classify as durable. \
                Classified otherwise, a write that moves only this field lands \
                silently and every consumer off the live-title channel freezes \
                until something else publishes `groups` (#311).
                """
            )
        }
    }

    // MARK: - Chrome text

    @Test("a displayed-title move alone is display-only")
    func titleMoveIsDisplayOnly() {
        let old = Self.basePane()
        var new = old
        new.title = "cargo build"

        #expect(PaneLayoutReducer.paneChangeKind(from: old, to: new) == .displayOnly)
    }

    @Test("a live-title move behind a frozen displayed title is display-only")
    func liveTitleMoveIsDisplayOnly() {
        let old = Self.basePane()
        var new = old
        new.liveTerminalTitle = "cargo build"

        // The ~10 Hz case: `isTitleUserEdited` froze `title`, so only the runtime
        // cache moves. Nothing renders it, but the reducer must still commit it —
        // `resetPaneTitle` reads it.
        #expect(PaneLayoutReducer.paneChangeKind(from: old, to: new) == .displayOnly)
    }

    @Test("an identical pane is unchanged")
    func identicalPaneIsUnchanged() {
        let pane = Self.basePane()

        #expect(PaneLayoutReducer.paneChangeKind(from: pane, to: pane) == .unchanged)
    }

    @Test("a durable move alongside a title move is durable, not display-only")
    func durableWinsOverTitle() {
        let old = Self.basePane()
        var new = old
        new.title = "cargo build"
        new.liveTerminalTitle = "cargo build"
        new.workingDirectory = "/var"

        // Title + cwd in one report is an ordinary `cd` in a prompt hook, so this
        // combination is the common case, not an edge one.
        #expect(PaneLayoutReducer.paneChangeKind(from: old, to: new) == .durable)
    }

    // MARK: - The structural check

    /// The drift this replaces the old two-list arrangement to prevent. Adding a
    /// field to `updatePane` without adding it to `paneChangeKind` would make the
    /// reducer discard the write entirely (it would classify `.unchanged`), so
    /// this fails loudly rather than shipping a silent freeze.
    ///
    /// Source-scraped because the set of fields a function assigns is not
    /// reachable at runtime; `Mirror` over `TerminalPane` would see all ~25
    /// stored properties, most of which `updatePane` cannot touch.
    @Test("paneChangeKind compares every field updatePane assigns")
    func classificationCoversEveryAssignedField() throws {
        let source = try SourceContract.source(at: Self.reducerPath)
        let updateBody = try SourceContract.declarationBody(
            after: "static func updatePane(",
            in: source,
            path: Self.reducerPath
        )
        let classifierBody = try SourceContract.declarationBody(
            after: "static func paneChangeKind(",
            in: source,
            path: Self.reducerPath
        )

        // `pane` is `updatePane`'s local copy. Other pane-valued locals in the
        // file are capitalised (`originalPane`, `activePane`), so this
        // case-sensitive match cannot pick up a read of the untouched snapshot.
        let assignment = try Regex(#"\bpane\.([A-Za-z0-9_]+) = "#)
        let assigned = Set(
            updateBody.matches(of: assignment).compactMap { match in
                (match[1].substring).map(String.init)
            }
        )

        #expect(
            assigned.count >= 10,
            """
            Found only \(assigned.count) `pane.<field> = ` assignments in \
            `updatePane`. This scan is the whole substance of this test, so too \
            few matches means the scan broke, not that the function got simpler — \
            check whether the assignments were reformatted away from \
            `pane.field = value` on one line.
            """
        )

        for field in assigned.sorted() {
            #expect(
                classifierBody.contains(".\(field) != "),
                """
                `updatePane` assigns `pane.\(field)` but `paneChangeKind` never \
                compares it, so a report that moves only that field classifies as \
                `.unchanged` and the reducer throws the write away. Add \
                `new.\(field) != old.\(field)` to the durable branch (or, if it is \
                chrome text with nothing behind it, to the display-only branch).
                """
            )
        }
    }
}
