import AppKit
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

@Suite("Document copy mode policy")
struct DocumentCopyModePolicyTests {
    @Test("copy mode uses localized literal values")
    func localizedPresentationValues() {
        let copying = DocumentCopyModePresentation(isCopyMode: true)
        #expect(copying.controlTitle == "Copy Mode")
        #expect(copying.helpText == "Return to commenting")

        let review = DocumentCopyModePresentation(isCopyMode: false)
        #expect(review.controlTitle == "Copy Mode")
        #expect(review.helpText == "Select and copy without creating comments")
    }

    @Test("copy mode localized literals exist in the string catalog")
    func localizedPresentationCatalogCoverage() throws {
        let literals = try AwesoMuxStringCatalog.localizedLiterals(
            in: "Sources/awesoMux/Views/DocumentCopyModePolicy.swift")
        let expected = Set([
            "Copy Mode",
            "Return to commenting",
            "Select and copy without creating comments",
        ])

        #expect(Set(literals) == expected)
        #expect(expected.isSubset(of: try AwesoMuxStringCatalog.keys()))
    }

    @Test("copy mode is available with no comments")
    func availableWithoutComments() {
        #expect(DocumentCopyModePolicy.isAvailable(in: projection()))
    }

    @Test("copy mode is available when every comment is resolved")
    func availableWhenAllCommentsAreResolved() {
        let doc = document(
            annotations: [
                annotation(id: "inline", status: .resolved, anchor: .span),
                annotation(id: "note", status: .resolved, anchor: .document),
            ])

        let projection = DocumentAnnotationProjection(document: doc)
        #expect(DocumentCopyModePolicy.isAvailable(in: projection))
        #expect(projection.documentNote?.id == "note")
        #expect(projection.resolvedSpanIDs == ["inline"])
        #expect(projection.resolvedSpanCount == 1)
    }

    @Test("an open inline comment or document note keeps the document in review mode")
    func unavailableWithOpenComment() {
        let inline = document(
            annotations: [annotation(id: "inline", status: .open, anchor: .span)])
        let note = document(
            annotations: [annotation(id: "note", status: .open, anchor: .document)])

        #expect(!DocumentCopyModePolicy.isAvailable(in: DocumentAnnotationProjection(document: inline)))
        #expect(!DocumentCopyModePolicy.isAvailable(in: DocumentAnnotationProjection(document: note)))
    }

    @Test("a newly opened comment immediately makes a requested copy mode inactive")
    func openCommentDeactivatesRequestedCopyMode() {
        let resolved = document(
            annotations: [annotation(id: "inline", status: .resolved, anchor: .span)])
        let reopened = document(
            annotations: [annotation(id: "inline", status: .open, anchor: .span)])

        #expect(
            DocumentCopyModePolicy.isActive(
                requested: true,
                projection: DocumentAnnotationProjection(document: resolved)
            ))
        #expect(
            !DocumentCopyModePolicy.isActive(
                requested: true,
                projection: DocumentAnnotationProjection(document: reopened)
            ))
    }

    @Test("copy mode hides resolved inline markup")
    func copyModeHidesResolvedInlineMarkup() {
        let doc = document(
            annotations: [
                annotation(id: "inline", status: .resolved, anchor: .span),
                annotation(id: "note", status: .resolved, anchor: .document),
            ])

        #expect(
            DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: DocumentAnnotationProjection(document: doc),
                copyModeAvailable: true,
                isCopyMode: true,
                hideResolved: false
            ) == ["inline"])
    }

    @Test("the existing resolved filter remains independent outside copy mode")
    func resolvedFilterRemainsIndependent() {
        let doc = document(
            annotations: [
                annotation(id: "resolved", status: .resolved, anchor: .span),
                annotation(id: "open", status: .open, anchor: .span),
            ])

        #expect(
            DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: DocumentAnnotationProjection(document: doc),
                copyModeAvailable: false,
                isCopyMode: false,
                hideResolved: false
            ).isEmpty)
        #expect(
            DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: DocumentAnnotationProjection(document: doc),
                copyModeAvailable: false,
                isCopyMode: false,
                hideResolved: true
            ) == ["resolved"])
    }

    @Test("review mode shows resolved markup after the last open comment closes")
    func completedReviewIgnoresStaleResolvedFilter() {
        let doc = document(
            annotations: [annotation(id: "resolved", status: .resolved, anchor: .span)])

        #expect(
            DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: DocumentAnnotationProjection(document: doc),
                copyModeAvailable: true,
                isCopyMode: false,
                hideResolved: true
            ).isEmpty)
    }

    @Test("the resolved filter remains active when an external gate disables copy mode")
    func resolvedFilterRemainsActiveWhenCopyModeIsExternallyUnavailable() {
        let doc = document(
            annotations: [annotation(id: "resolved", status: .resolved, anchor: .span)])

        #expect(
            DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: DocumentAnnotationProjection(document: doc),
                copyModeAvailable: false,
                isCopyMode: false,
                hideResolved: true
            ) == ["resolved"])
    }

    private func document(annotations: [PlanAnnotation] = []) -> RenderedDocument {
        RenderedDocument(source: "", runs: [], annotations: annotations, taskProgress: .init(done: 0, total: 0))
    }

    private func projection(annotations: [PlanAnnotation] = []) -> DocumentAnnotationProjection {
        DocumentAnnotationProjection(document: document(annotations: annotations))
    }

    private func annotation(
        id: String,
        status: PlanAnnotationStatus,
        anchor: PlanAnnotation.Anchor
    ) -> PlanAnnotation {
        PlanAnnotation(
            id: id,
            author: .user,
            status: status,
            payload: "Comment",
            anchor: anchor
        )
    }
}

@Suite("Document copy mode selection")
@MainActor
struct DocumentCopyModeSelectionTests {
    @Test("copy selection remains intact while comment creation is disabled")
    func copySelectionRemainsIntact() {
        let document = AttributedMarkdownBuilder.build("Copy this response")
        let textView = NSTextView()
        textView.string = document.runs.map(\.text).joined()
        textView.setSelectedRange(NSRange(location: 0, length: 4))

        let coordinator = MarkdownTextViewCoordinator(selectedSourceSpan: .constant(nil))
        coordinator.lastDoc = document
        coordinator.annotationsInteractive = false
        var presentedComposer = false
        coordinator.onSelectionFinalized = { _, _, _ in
            presentedComposer = true
        }

        coordinator.handleSelectionFinished(in: textView)

        #expect(textView.selectedRange() == NSRange(location: 0, length: 4))
        #expect(!presentedComposer)
    }
}
