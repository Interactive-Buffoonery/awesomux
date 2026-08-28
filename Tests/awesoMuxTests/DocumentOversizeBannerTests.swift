import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// The 2 MiB cap is a memory ceiling, so a document growing past it is a
/// routine event rather than an error — an agent appending to an open plan
/// file crosses it in normal use. These lock the branch that decides whether
/// the reader keeps the document they were reading or gets an error page.
@Suite("Document oversize policy")
struct DocumentOversizePolicyTests {
    private static let loaded = DocumentLoader.LoadResult.loaded(
        source: "# plan\n", snapshot: nil)

    @Test("an over-cap reload keeps the last good render instead of replacing it")
    func overCapWithPriorRenderRetains() {
        #expect(
            DocumentOversizePolicy.decide(
                result: .rejected(.tooLarge),
                hasPriorRender: true,
                isBannerShowing: false
            ) == .retainRender)
    }

    @Test("a later over-cap reload keeps the banner up rather than re-deciding")
    func overCapWhileBannerShowingStillRetains() {
        #expect(
            DocumentOversizePolicy.decide(
                result: .rejected(.tooLarge),
                hasPriorRender: true,
                isBannerShowing: true
            ) == .retainRender)
    }

    /// A tab whose file is already over cap on first mount has nothing behind
    /// a banner. Retaining there would show an empty pane with a notice about
    /// a version the user never saw.
    @Test("a first mount that is already over cap falls through to the error page")
    func overCapWithoutPriorRenderApplies() {
        #expect(
            DocumentOversizePolicy.decide(
                result: .rejected(.tooLarge),
                hasPriorRender: false,
                isBannerShowing: false
            ) == .apply)
    }

    /// Only the size rejection is retained. Every other failure means the
    /// bytes behind the mounted render are gone or unreachable, so continuing
    /// to show them would be a lie.
    @Test(
        "no other failure retains the render",
        arguments: [
            DocumentLoader.LoadResult.rejected(.unreadable),
            .rejected(.badExtension),
            .rejected(.notFileURL),
            .readError("boom"),
        ])
    func onlySizeRejectionRetains(result: DocumentLoader.LoadResult) {
        #expect(
            DocumentOversizePolicy.decide(
                result: result,
                hasPriorRender: true,
                isBannerShowing: false
            ) == .apply)
    }

    /// A read failure while the banner is up must surface immediately — the
    /// settle window is only for promoting a *recovered* document.
    @Test("a read failure while the banner is up is applied at once")
    func readErrorWhileBannerShowingApplies() {
        #expect(
            DocumentOversizePolicy.decide(
                result: .readError("boom"),
                hasPriorRender: true,
                isBannerShowing: true
            ) == .apply)
    }

    /// A non-atomic writer truncates and rewrites: for a moment the file holds
    /// a valid but INCOMPLETE prefix that is under the cap, and that moment can
    /// outlast the watcher's ~100 ms debounce. Promoting it immediately would
    /// leave the banner protecting half a document once the writer finishes
    /// back over cap.
    @Test("a recovered read waits out a settle window before it is promoted")
    func recoveredReadSettles() {
        #expect(
            DocumentOversizePolicy.decide(
                result: Self.loaded,
                hasPriorRender: true,
                isBannerShowing: true
            ) == .settle)
    }

    @Test("a normal successful load is applied without waiting")
    func normalLoadApplies() {
        #expect(
            DocumentOversizePolicy.decide(
                result: Self.loaded,
                hasPriorRender: true,
                isBannerShowing: false
            ) == .apply)
    }

    /// The window has to outlast a non-atomic rewrite, which is exactly the
    /// judgement `DocumentGroupView.resolveSettleInterval` already made for
    /// the all-comments-resolved notice. Drifting shorter re-opens the hole.
    @Test("the settle window is at least the group view's resolve window")
    func settleWindowMatchesTheEstablishedOne() {
        #expect(DocumentOversizePolicy.settleInterval >= .milliseconds(500))
    }
}

// MARK: - Banner copy

@Suite("Document oversize banner copy")
struct DocumentOversizeBannerCopyTests {
    /// The rendered markdown body is a single `.staticText` element labelled
    /// "Document content", so no heading inside the document is reachable as
    /// structure — this label is the only thing that tells a screen reader
    /// user the view has stopped tracking the file.
    @Test("the spoken label names the file and states the cap")
    func accessibilityLabelNamesFileAndCap() {
        let label = DocumentOversizeBanner.accessibilityLabel(fileName: "quarterly-plan.md")

        #expect(label.contains("quarterly-plan.md"), "should name the file: \(label)")
        #expect(
            label.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"),
            "should state the enforced cap: \(label)")
        // No `!contains("%arg")` here on purpose: the catalog is not a declared
        // SwiftPM resource, so under `swift test` `String(localized:)` always
        // formats the source literal and such an assertion cannot fail. The
        // catalog suite below asserts key agreement against the file itself.
    }

    /// The cap has to come from the validator, not a hand-typed number, or the
    /// copy drifts from the number actually enforced the next time it moves.
    @Test("the visible detail states the enforced cap")
    func detailStatesTheEnforcedCap() {
        #expect(
            DocumentOversizeBanner.detail.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"),
            "expected the enforced cap: \(DocumentOversizeBanner.detail)")
    }

    /// Losing the ability to comment is the change users actually collide
    /// with, and it is the one the pixels do not explain: "Add Document Note"
    /// simply goes `.disabled`, which VoiceOver reads as "dimmed, button" with
    /// no cause. `detail` feeds both the visible row and the accessibility
    /// label, so it is the single place that can say it.
    @Test("the detail states that commenting is paused, not only that the file grew")
    func detailStatesTheReadOnlyTransition() {
        #expect(
            DocumentOversizeBanner.detail.lowercased().contains("comments are paused"),
            "the banner never mentions the read-only transition: \(DocumentOversizeBanner.detail)")
    }

    /// The file reads back perfectly well — it is too large to *render*.
    /// "Can no longer be reloaded" sent the reader looking for a permissions
    /// or disk fault that isn't there, and it is the first thing spoken.
    @Test("the spoken lead-in does not claim the file cannot be read")
    func accessibilityLabelDoesNotClaimAReadFailure() {
        let label = DocumentOversizeBanner.accessibilityLabel(fileName: "plan.md")

        #expect(
            !label.lowercased().contains("reloaded"),
            "the lead-in still claims a read failure: \(label)")
        #expect(
            label.lowercased().contains("too large to render"),
            "the lead-in should name rendering as the limit: \(label)")
    }
}

// MARK: - Cross-remount over-cap state

/// `.settle` is only reachable while the banner is up, and the banner is view
/// `@State`. A tab switch inside a non-atomic writer's truncate-and-rewrite
/// window therefore used to remount into a banner-free state and `.apply` the
/// half-written prefix — which is worse than a flicker, because `.apply`
/// reports the render to `DocumentTabMemory` and the `isRejectedForSize` skip
/// does not cover a `.loaded` prefix. The policy keeps the bit keyed by path so
/// it outlives the view.
@Suite("Document oversize cross-remount state", .serialized)
@MainActor
struct DocumentOversizeRemountStateTests {
    private static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/awesoMux/Views/DocumentPaneView.swift")

    @Test("an over-cap file stays marked so a remount can raise the banner at once")
    func oversizeSurvivesTheView() {
        let path = "/tmp/awesomux-oversize-\(UUID().uuidString).md"
        defer { DocumentOversizePolicy.noteOversize(false, path: path) }

        #expect(DocumentOversizePolicy.isOversize(path: path) == false)
        DocumentOversizePolicy.noteOversize(true, path: path)
        #expect(DocumentOversizePolicy.isOversize(path: path))
    }

    @Test("a file that drops back under the cap is unmarked")
    func recoveryClearsTheMark() {
        let path = "/tmp/awesomux-oversize-\(UUID().uuidString).md"
        DocumentOversizePolicy.noteOversize(true, path: path)
        DocumentOversizePolicy.noteOversize(false, path: path)

        #expect(DocumentOversizePolicy.isOversize(path: path) == false)
    }

    /// The seed is what closes the remount hole, and there is no seam to
    /// observe it from — `showsOversizeBanner` is private `@State` and a hosted
    /// `DocumentPaneView` cannot be driven to the settle path without a real
    /// file, a real watcher and real timing. Pin the wiring instead.
    @Test("the pane seeds its banner state from the policy at init")
    func initSeedsTheBannerFromThePolicy() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)

        #expect(
            text.contains("_showsOversizeBanner = State("),
            "showsOversizeBanner must be seeded in init, or a remount loses the settle window")
        #expect(
            text.contains("DocumentOversizePolicy.isOversize("),
            "the init seed must read the cross-remount policy state")
    }
}

// MARK: - Read-only gating

/// The banner keeps a `.loaded` result mounted whose snapshot describes bytes
/// the disk no longer has. Every annotation write path gates on a non-nil
/// snapshot, so withholding it is the one place that takes the whole surface
/// read-only. If it stayed live, each save would commit against a stale
/// observation, conflict, reload, land back on the size rejection, and invite
/// the user to try again — a loop with no exit.
@Suite("Document oversize read-only gating")
struct DocumentOversizeReadOnlyTests {
    private static func snapshot() throws -> MarkdownDocumentSnapshot {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-oversize-gate-\(UUID().uuidString).md")
        try "# plan\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(DocumentLoader.readSnapshot(url))
    }

    @Test("no snapshot is offered to the annotation surface while the banner is up")
    func bannerWithholdsTheSnapshot() throws {
        let snapshot = try Self.snapshot()

        #expect(
            DocumentPaneView.editableSnapshot(snapshot, isBannerShowing: true) == nil,
            "an editable snapshot while the banner is up puts every save into a conflict-reload loop")
    }

    @Test("the snapshot passes through untouched when the banner is down")
    func noBannerPassesTheSnapshotThrough() throws {
        let snapshot = try Self.snapshot()

        #expect(DocumentPaneView.editableSnapshot(snapshot, isBannerShowing: false) == snapshot)
    }
}

// MARK: - Over-cap save outcome

/// `editableSnapshot` only gates presentation-time construction, and the
/// comment popovers are `NSHostingController` root views handed over
/// imperatively: their save closures capture the snapshot by value at open
/// time and nothing re-renders them when the file crosses the cap. The write
/// path therefore has to answer with an outcome those editors treat as
/// terminal — otherwise Save stays live, each attempt reloads back into the
/// banner, and the user is invited to try again forever.
@Suite("Over-cap annotation save outcome")
struct OversizeAnnotationOutcomeTests {
    @Test("a mid-save cap crossing becomes terminal after reload")
    func midSaveCapCrossingBecomesTerminal() {
        #expect(
            AnnotationSaveRecovery.outcome(
                afterReloading: .inputTooLarge,
                conflictOutcome: .reloadAndRetry
            ) == .oversizeCopyOnly)
    }

    @Test("an ordinary conflict keeps its caller-specific recovery")
    func ordinaryConflictKeepsItsRecovery() {
        #expect(
            AnnotationSaveRecovery.outcome(
                afterReloading: .observedConflict,
                conflictOutcome: .copyAndReselect
            ) == .copyAndReselect)
    }

    /// `copyOnly` is terminal only for an existing annotation and
    /// `copyAndReselect` only for a new one, so neither could carry this case:
    /// an open compose popover would have kept a working Save.
    @Test("the over-cap outcome disables submit for an existing annotation")
    func terminalForExistingAnnotation() {
        #expect(
            AnnotationSaveRecovery.canSubmitExistingAnnotation(
                isSubmitting: false,
                outcome: .oversizeCopyOnly
            ) == false)
    }

    /// The suspension has to be withdrawn when its cause goes away. Nothing
    /// else clears `.oversizeCopyOnly`, and it is the only thing still
    /// disabling Submit, so a sheet left holding it strands a draft the disk
    /// would now accept.
    @Test("the file fitting again withdraws the suspension")
    func editingAllowedAgainClearsTheSuspension() {
        #expect(
            AnnotationSaveRecovery.recovery(
                afterEditingAllowed: true,
                isEditing: true,
                current: .oversizeCopyOnly
            ) == nil)
    }

    /// A real failure recorded something that actually happened; only the
    /// size suspension is provisional.
    @Test(
        "recovering editability leaves every other parked outcome alone",
        arguments: [
            AnnotationSaveOutcome.copyOnly,
            .copyAndReselect,
            .failed,
        ])
    func editingAllowedAgainPreservesRealFailures(outcome: AnnotationSaveOutcome) {
        #expect(
            AnnotationSaveRecovery.recovery(
                afterEditingAllowed: true,
                isEditing: false,
                current: outcome
            ) == outcome)
    }

    @Test("losing editability mid-edit parks the suspension")
    func editingDisallowedWhileEditingParks() {
        #expect(
            AnnotationSaveRecovery.recovery(
                afterEditingAllowed: false,
                isEditing: true,
                current: nil
            ) == .oversizeCopyOnly)
    }

    /// A sheet merely *viewing* a note has no draft at risk, so there is
    /// nothing to suspend and no reason to show a recovery affordance.
    @Test("losing editability while only viewing parks nothing")
    func editingDisallowedWhileViewingIsInert() {
        #expect(
            AnnotationSaveRecovery.recovery(
                afterEditingAllowed: false,
                isEditing: false,
                current: nil
            ) == nil)
    }

    @Test("the over-cap outcome disables submit for a new annotation")
    func terminalForNewAnnotation() {
        #expect(
            AnnotationSaveRecovery.canSubmitNewAnnotation(
                hasValidDraft: true,
                isSubmitting: false,
                outcome: .oversizeCopyOnly
            ) == false)
    }

    /// The reason has to reach the user, not just the disabled state — the
    /// same complaint the banner copy answers. One string across both
    /// popovers, the note sheet and the announcement so they cannot drift.
    @Test("the over-cap message names the enforced cap")
    func messageNamesTheCap() {
        #expect(
            AnnotationSaveRecovery.oversizeMessage
                .contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"),
            "expected the enforced cap: \(AnnotationSaveRecovery.oversizeMessage)")
    }

    @Test("the over-cap outcome is announced rather than passing silently")
    func announced() {
        #expect(AnnotationSaveRecovery.announcement(for: .oversizeCopyOnly) != nil)
    }
}

// MARK: - Load-task structure

/// `guardedWrite`'s `.observedConflict` branch awaits
/// `DocumentReloadCompletion.wait(for:)`, whose continuation resumes ONLY from
/// `complete()` or `invalidate()`. The banner adds an early return to the load
/// task, and an early return placed above the completion call would hang that
/// await forever — with the submitting popover set to `.applicationDefined`
/// (non-transient), so the user gets a wedged, undismissable popover rather
/// than a stuck spinner.
///
/// There is no seam to observe that from: the completion object is view
/// `@State`, and a hosted `DocumentPaneView` cannot be driven to the conflict
/// path without a real file, a real watcher and real timing. What *is*
/// checkable is the structure that makes the mistake impossible — the call is
/// registered with `defer`, so every path out of the task runs it. This fails
/// if anyone converts it back to a plain statement that a branch can skip.
@Suite("Document load task completion structure")
struct DocumentLoadCompletionStructureTests {
    private static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/awesoMux/Views/DocumentPaneView.swift")

    @Test("the reload completion is registered with defer, not called from a branch")
    func completionIsDeferred() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let calls = text.components(separatedBy: "reloadCompletion.complete(").count - 1

        #expect(calls == 1, "expected exactly one completion call site, found \(calls)")
        #expect(
            text.contains("defer { reloadCompletion.complete(reloadTaskID.generation) }"),
            "the load task's reload completion must be registered with defer so no early return can skip it")
    }

    /// A substring check cannot see a `return` placed ABOVE the `defer`, so
    /// "every path out of the task runs it" is only true of the body that
    /// follows it. The settle block returns on cancellation, so the `defer`
    /// has to precede it for the claim to hold of the whole task.
    @Test("the defer precedes the settle window's early returns")
    func deferPrecedesTheSettleBlock() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let deferOffset = try #require(
            text.range(of: "defer { reloadCompletion.complete(reloadTaskID.generation) }")?
                .lowerBound)
        let settleOffset = try #require(text.range(of: "if decision == .settle {")?.lowerBound)

        #expect(
            deferOffset < settleOffset,
            "the settle block returns early on cancellation, so the completion defer must be registered before it")
    }

    /// The banner's trigger is an agent writing to the file — precisely when
    /// the sibling terminal is loudest with AX traffic. `.medium` is queued
    /// and preemptible; every comparable state transition in this app
    /// (`announceWaitingForInput`, workspace-closed, settings errors) is
    /// `.high`, and this one is the only signal a screen reader gets that the
    /// view stopped tracking the file.
    @Test("the banner announcement is posted at high priority")
    func bannerAnnouncementIsHighPriority() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let call = try #require(
            text.range(of: "DocumentOversizeBanner.accessibilityLabel(fileName: pane.title)"))
        let tail = text[call.upperBound...].prefix(80)

        #expect(
            tail.contains("priority: .high"),
            "the oversize announcement must not default to the queued, preemptible .medium priority")
    }

    /// `triggerWatcherReload` retains the captured scroll anchor for every nil
    /// snapshot, but `readSnapshot` returns nil for a deleted, unreadable,
    /// wrong-extension or non-UTF-8 file too — not only for an over-cap one.
    /// Those tear the document down to the error page, where the anchor is a
    /// byte offset into a document that no longer exists; left set it survives
    /// in `@State` and scrolls the reader into the middle of whatever comes
    /// back next. Cleared in the load task so every caller is covered at once.
    @Test("a non-loaded result clears the pending scroll anchor")
    func nonLoadedResultClearsTheScrollAnchor() throws {
        // Whitespace-stripped rather than pinned verbatim: `swift-format`
        // reflows this block, so an exact-text assertion would put the test and
        // `script/format.sh --lint` in direct contradiction. A `switch` (not an
        // `if case`) so a new `LoadResult` case forces a decision here.
        let compact = try String(contentsOf: Self.source, encoding: .utf8)
            .replacing(try Regex(#"\s+"#), with: "")

        #expect(
            compact.contains("case.rejected,.readError:pendingScrollAnchor=nil"),
            "the load task must clear the retained scroll anchor when the result is not .loaded")
    }
}

// MARK: - Catalog coverage

/// `Resources/Localizable.xcstrings` is not a declared SwiftPM resource, so
/// under `swift test` `String(localized:)` always falls back to formatting the
/// source literal. Every assertion on a *rendered* string therefore passes
/// whether the catalog entry is correct, malformed, or absent — this reads the
/// catalog the shipped app actually loads instead.
@Suite("Document oversize banner localization catalog coverage")
struct DocumentOversizeBannerCatalogTests {

    /// `AnnotationSaveRecovery` is here too because it now owns the one
    /// over-cap sentence every editing surface renders — the popovers, the
    /// note sheet and the announcement all read it, so a missing key would
    /// leak `%arg` to four places at once.
    @Test(
        arguments: [
            "Sources/awesoMux/Views/DocumentOversizeBanner.swift",
            "Sources/awesoMux/Views/Markdown/AnnotationSaveRecovery.swift",
        ])
    func everyLocalizedLiteralIsACatalogKey(relativePath: String) throws {
        let keys = try AwesoMuxStringCatalog.keys()
        let literals = try AwesoMuxStringCatalog.localizedLiterals(in: relativePath)

        #expect(!literals.isEmpty, "found no localized literals — parser drift?")
        for literal in literals {
            #expect(
                keys.contains(literal),
                "\(relativePath) localizes \"\(literal)\" but Localizable.xcstrings has no such key")
        }
    }

    /// The kicker is a bare SwiftUI `Text`, which the literal regex above
    /// cannot see, so it is named explicitly.
    @Test func theBannerKickerIsACatalogKey() throws {
        #expect(try AwesoMuxStringCatalog.keys().contains("file outgrew the limit"))
    }
}
