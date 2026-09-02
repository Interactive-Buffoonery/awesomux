import AwesoMuxCore
import Foundation

struct DocumentCopyModePresentation: Equatable {
    let controlTitle: String
    let helpText: String

    init(isCopyMode: Bool) {
        controlTitle = String(
            localized: "Copy Mode",
            comment: "Stable toggle title for copy-friendly document mode."
        )
        if isCopyMode {
            helpText = String(
                localized: "Return to commenting",
                comment: "Help text for the Copy Mode toggle while it is active."
            )
        } else {
            helpText = String(
                localized: "Select and copy without creating comments",
                comment: "Help text for the Copy Mode toggle while it is inactive."
            )
        }
    }
}

struct DocumentAnnotationProjection: Equatable {
    let documentNote: PlanAnnotation?
    let resolvedSpanIDs: Set<String>
    let resolvedSpanCount: Int
    let hasOpenAnnotations: Bool

    init(document: RenderedDocument) {
        var documentNote: PlanAnnotation?
        var resolvedSpanIDs: Set<String> = []
        var hasOpenAnnotations = false

        for annotation in document.annotations {
            if annotation.anchor == .document, documentNote == nil {
                documentNote = annotation
            }
            if annotation.status == .open {
                hasOpenAnnotations = true
            } else if annotation.anchor == .span {
                resolvedSpanIDs.insert(annotation.id)
            }
        }

        self.documentNote = documentNote
        self.resolvedSpanIDs = resolvedSpanIDs
        self.resolvedSpanCount = resolvedSpanIDs.count
        self.hasOpenAnnotations = hasOpenAnnotations
    }
}

enum DocumentCopyModePolicy {
    static func isAvailable(in projection: DocumentAnnotationProjection) -> Bool {
        !projection.hasOpenAnnotations
    }

    static func isActive(
        requested: Bool,
        projection: DocumentAnnotationProjection
    ) -> Bool {
        requested && isAvailable(in: projection)
    }

    static func hiddenAnnotationIDs(
        in projection: DocumentAnnotationProjection,
        isCopyMode: Bool,
        hideResolved: Bool
    ) -> Set<String> {
        if isAvailable(in: projection) {
            return isCopyMode ? projection.resolvedSpanIDs : []
        }
        return hideResolved ? projection.resolvedSpanIDs : []
    }
}
