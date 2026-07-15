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
            AnnotationSaveRecovery.reboundSource(
                annotationID: "note-1",
                openedDocument: opened,
                currentDocument: reloaded
            ) == "external edit"
        )
    }

    @Test("requires copy recovery when the stable id disappears")
    func preservesDraftWhenAnnotationDisappears() {
        let opened = document(source: "old", annotationID: "note-1")
        let reloaded = document(source: "external edit", annotationID: "note-2")

        #expect(
            AnnotationSaveRecovery.reboundSource(
                annotationID: "note-1",
                openedDocument: opened,
                currentDocument: reloaded
            ) == nil
        )
    }

    private func document(source: String, annotationID: String) -> RenderedDocument {
        RenderedDocument(
            source: source,
            runs: [],
            annotations: [
                PlanAnnotation(
                    id: annotationID,
                    author: .user,
                    payload: "draft",
                    anchor: .span
                )
            ],
            taskProgress: TaskProgress(done: 0, total: 0)
        )
    }
}
