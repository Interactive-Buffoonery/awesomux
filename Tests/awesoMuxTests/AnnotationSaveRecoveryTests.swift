import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Annotation save recovery")
struct AnnotationSaveRecoveryTests {
    @Test("blocks duplicate submissions until the active save finishes")
    func blocksDuplicateSubmissions() async {
        var gate = AnnotationSubmissionGate()

        let first = gate.begin()
        await Task.yield()
        let duplicate = gate.begin()
        #expect(first)
        #expect(!duplicate)

        gate.finish()
        let retry = gate.begin()
        #expect(retry)
    }

    @Test("rebinds an existing draft to its stable id after reload")
    func rebindsExistingDraft() {
        let opened = document(source: "old", annotationID: "note-1")
        let reloaded = document(source: "external edit", annotationID: "note-1")

        #expect(
            AnnotationSaveRecovery.canRebind(
                annotationID: "note-1",
                openedDocument: opened,
                currentDocument: reloaded
            )
        )
    }

    @Test("requires copy recovery when the stable id disappears")
    func preservesDraftWhenAnnotationDisappears() {
        let opened = document(source: "old", annotationID: "note-1")
        let reloaded = document(source: "external edit", annotationID: "note-2")

        #expect(
            !AnnotationSaveRecovery.canRebind(
                annotationID: "note-1",
                openedDocument: opened,
                currentDocument: reloaded
            )
        )
    }

    @Test("does not rebind when the same annotation changed unseen")
    func refusesChangedAnnotation() {
        let opened = document(source: "old", annotationID: "note-1", payload: "first")
        let reloaded = document(
            source: "external edit",
            annotationID: "note-1",
            payload: "changed elsewhere"
        )

        #expect(
            !AnnotationSaveRecovery.canRebind(
                annotationID: "note-1",
                openedDocument: opened,
                currentDocument: reloaded
            )
        )
    }

    @MainActor
    @Test("reload wait completes only after the requested generation")
    func waitsForReloadCompletion() async {
        let completion = DocumentReloadCompletion()
        var didFinish = false
        let waiter = Task { @MainActor in
            _ = await completion.wait(for: 2)
            didFinish = true
        }
        await Task.yield()

        completion.complete(1)
        await Task.yield()
        #expect(!didFinish)

        completion.complete(2)
        await waiter.value
        #expect(didFinish)
    }

    @MainActor
    @Test("invalidation releases current waits and rejects late conflict waits")
    func invalidationTerminatesConflictWaits() async {
        let completion = DocumentReloadCompletion()
        let current = Task { @MainActor in
            await completion.wait(for: 2)
        }
        await Task.yield()

        completion.invalidate()

        #expect(await current.value == false)
        #expect(await completion.wait(for: 3) == false)
    }

    @Test("document-note retry rebinds from the opening snapshot after reload")
    func rebindsNewDocumentNoteAfterConflictReload() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-document-note-retry")
        let file = directory.url.appending(path: "plan.md")
        try Data("# Opening\n".utf8).write(to: file)
        let openedSnapshot = try snapshot(at: file)

        try Data("# External edit\n".utf8).write(to: file)
        let firstSave = MarkdownDocumentCommitter.commitObserved(
            at: file,
            observed: openedSnapshot,
            transform: { source in
                PlanAnnotationWriter.appendingDocumentAnnotation(
                    in: source,
                    author: .user,
                    payload: "Keep this draft"
                )?.source
            }
        )
        #expect(firstSave == .observedConflict)

        let currentSnapshot = try snapshot(at: file)
        let currentDocument = AttributedMarkdownBuilder.build(try #require(currentSnapshot.source))
        let rebound = try #require(
            AnnotationSaveRecovery.snapshotForNewDocumentNote(
                openedSnapshot: openedSnapshot,
                currentSnapshot: currentSnapshot,
                currentDocument: currentDocument
            )
        )
        let retry = MarkdownDocumentCommitter.commitObserved(
            at: file,
            observed: rebound,
            transform: { source in
                PlanAnnotationWriter.appendingDocumentAnnotation(
                    in: source,
                    author: .user,
                    payload: "Keep this draft"
                )?.source
            }
        )

        guard case .committed = retry else {
            Issue.record("Expected retry to commit, got \(retry)")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Keep this draft"))
    }

    @Test("document-note retry refuses an externally added note")
    func refusesExternalDocumentNoteOnRetry() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-document-note-retry")
        let file = directory.url.appending(path: "plan.md")
        try Data("# Opening\n".utf8).write(to: file)
        let openedSnapshot = try snapshot(at: file)
        try Data("# Opening\n\n<!-- AMX id=q3k7 by=user: External note -->\n".utf8)
            .write(to: file)
        let currentSnapshot = try snapshot(at: file)
        let currentDocument = AttributedMarkdownBuilder.build(try #require(currentSnapshot.source))

        #expect(
            AnnotationSaveRecovery.snapshotForNewDocumentNote(
                openedSnapshot: openedSnapshot,
                currentSnapshot: currentSnapshot,
                currentDocument: currentDocument
            ) == nil
        )
    }

    @Test("submission lifecycle prevents transient dismissal")
    func submissionLifecycleBehavior() {
        #expect(AnnotationPopoverLifecycle.behavior(isSubmitting: true) == .applicationDefined)
        #expect(AnnotationPopoverLifecycle.behavior(isSubmitting: false) == .transient)
    }

    @Test("recovery and copy outcomes have spoken feedback")
    func recoveryAnnouncements() {
        #expect(AnnotationSaveRecovery.announcement(for: .reloadAndRetry)?.contains("Reload complete") == true)
        #expect(
            AnnotationSaveRecovery.announcement(
                for: .copyOnly,
                hasRecoverableDraft: false
            ) == "The annotation changed or was removed."
        )
        #expect(AnnotationSaveRecovery.copyAnnouncement(didCopy: true) == "Draft copied")
        #expect(AnnotationSaveRecovery.copyAnnouncement(didCopy: false) == "Draft could not be copied")
    }

    @Test("Return cannot resubmit a stale selection or an in-flight draft")
    func blocksUnsafeReturnSubmission() {
        #expect(
            !AnnotationSaveRecovery.canSubmitExistingAnnotation(
                isSubmitting: false,
                outcome: .copyOnly
            )
        )
        #expect(
            AnnotationSaveRecovery.canSubmitExistingAnnotation(
                isSubmitting: false,
                outcome: .reloadAndRetry
            )
        )
        #expect(
            !AnnotationSaveRecovery.canSubmitNewAnnotation(
                hasValidDraft: true,
                isSubmitting: false,
                outcome: .copyAndReselect
            )
        )
        #expect(
            !AnnotationSaveRecovery.canSubmitNewAnnotation(
                hasValidDraft: true,
                isSubmitting: true,
                outcome: nil
            )
        )
        #expect(
            AnnotationSaveRecovery.canSubmitNewAnnotation(
                hasValidDraft: true,
                isSubmitting: false,
                outcome: .reloadAndRetry
            )
        )
    }

    private func document(
        source: String,
        annotationID: String,
        payload: String = "draft"
    ) -> RenderedDocument {
        RenderedDocument(
            source: source,
            runs: [],
            annotations: [
                PlanAnnotation(
                    id: annotationID,
                    author: .user,
                    payload: payload,
                    anchor: .span
                )
            ],
            taskProgress: TaskProgress(done: 0, total: 0)
        )
    }

    private func snapshot(at file: URL) throws -> MarkdownDocumentSnapshot {
        guard case let .loaded(_, _, snapshot) = DocumentLoader.load(file), let snapshot else {
            throw CocoaError(.fileReadUnknown)
        }
        return snapshot
    }
}
