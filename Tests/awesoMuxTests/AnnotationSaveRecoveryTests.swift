import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Annotation save recovery")
struct AnnotationSaveRecoveryTests {

    @Test(arguments: [
        ("note-1", "draft", "draft", true),
        ("note-2", "draft", "draft", false),
        ("note-1", "first", "changed elsewhere", false),
    ])
    func rebindsOnlyUnchangedAnnotation(currentID: String, openingPayload: String, payload: String, expected: Bool) {
        let opened = document(source: "old", annotationID: "note-1", payload: openingPayload)
        let reloaded = document(source: "external edit", annotationID: currentID, payload: payload)
        #expect(
            AnnotationSaveRecovery.canRebind(
                annotationID: "note-1", openedDocument: opened,
                currentDocument: reloaded) == expected)
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

    @Test(arguments: [false, true])
    func documentNoteRecovery(externalNote: Bool) throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-document-note-retry")
        defer { withExtendedLifetime(directory) {} }
        let file = directory.url.appending(path: "plan.md")
        try Data("# Opening\n".utf8).write(to: file)
        let openedSnapshot = try snapshot(at: file)
        let edited = externalNote ? "# Opening\n\n<!-- AMX id=q3k7 by=user: External note -->\n" : "# External edit\n"
        try Data(edited.utf8).write(to: file)
        let transform: (String) -> String? = { source in
            PlanAnnotationWriter.appendingDocumentAnnotation(in: source, author: .user, payload: "Keep this draft")?.source
        }
        if !externalNote {
            #expect(MarkdownDocumentCommitter.commitObserved(at: file, observed: openedSnapshot, transform: transform) == .observedConflict)
        }
        let currentSnapshot = try snapshot(at: file)
        let currentDocument = AttributedMarkdownBuilder.build(try #require(currentSnapshot.source))
        let rebound = AnnotationSaveRecovery.snapshotForNewDocumentNote(
            openedSnapshot: openedSnapshot,
            currentSnapshot: currentSnapshot, currentDocument: currentDocument)
        if externalNote {
            #expect(rebound == nil)
        } else {
            let retry = MarkdownDocumentCommitter.commitObserved(at: file, observed: try #require(rebound), transform: transform)
            guard case .committed = retry else {
                Issue.record("Expected retry to commit, got \(retry)")
                return
            }
            #expect(try String(contentsOf: file, encoding: .utf8).contains("Keep this draft"))
        }
    }

    @Test(arguments: [
        (false, true, false, AnnotationSaveOutcome.copyOnly, false),
        (false, true, false, .reloadAndRetry, true),
        (true, true, false, .copyAndReselect, false),
        (true, true, true, nil, false),
        (true, true, false, .reloadAndRetry, true),
    ])
    func submissionGate(new: Bool, valid: Bool, submitting: Bool, outcome: AnnotationSaveOutcome?, expected: Bool) {
        let allowed =
            new
            ? AnnotationSaveRecovery.canSubmitNewAnnotation(hasValidDraft: valid, isSubmitting: submitting, outcome: outcome)
            : AnnotationSaveRecovery.canSubmitExistingAnnotation(isSubmitting: submitting, outcome: outcome)
        #expect(allowed == expected)
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
        guard case let .loaded(_, snapshot) = DocumentLoader.load(file), let snapshot else {
            throw CocoaError(.fileReadUnknown)
        }
        return snapshot
    }
}
