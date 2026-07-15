import AwesoMuxCore
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
            await completion.wait(for: 2)
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

    @Test("submission lifecycle prevents transient dismissal")
    func submissionLifecycleBehavior() {
        #expect(AnnotationPopoverLifecycle.behavior(isSubmitting: true) == .applicationDefined)
        #expect(AnnotationPopoverLifecycle.behavior(isSubmitting: false) == .transient)
    }

    @Test("recovery and copy outcomes have spoken feedback")
    func recoveryAnnouncements() {
        #expect(AnnotationSaveRecovery.announcement(for: .reloadAndRetry)?.contains("Reload complete") == true)
        #expect(AnnotationSaveRecovery.copyAnnouncement(didCopy: true) == "Draft copied")
        #expect(AnnotationSaveRecovery.copyAnnouncement(didCopy: false) == "Draft could not be copied")
    }

    @Test("Return cannot resubmit a stale selection or an in-flight draft")
    func blocksUnsafeReturnSubmission() {
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
}
