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
    @Test("reload waits finish at their generation or invalidation", arguments: [false, true])
    func waitsForReloadCompletion(invalidated: Bool) async {
        let completion = DocumentReloadCompletion()
        var didFinish = false
        let waiter = Task { @MainActor in
            let result = await completion.wait(for: 2)
            didFinish = true
            return result
        }
        await Task.yield()

        if invalidated {
            completion.invalidate()
            #expect(await waiter.value == false)
            #expect(await completion.wait(for: 3) == false)
        } else {
            completion.complete(1)
            await Task.yield()
            #expect(!didFinish)

            completion.complete(2)
            _ = await waiter.value
            #expect(didFinish)
        }
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
