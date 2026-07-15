import AwesoMuxCore

enum AnnotationSaveOutcome: Equatable, Sendable {
    case saved
    case reloadAndRetry
    case copyAndReselect
    case copyOnly
    case failed
}

struct AnnotationSubmissionGate {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }
}

enum AnnotationSaveRecovery {
    static func reboundSource(
        annotationID: String,
        openedDocument: RenderedDocument,
        currentDocument: RenderedDocument?
    ) -> String? {
        guard let currentDocument,
            currentDocument.source != openedDocument.source
        else { return openedDocument.source }

        guard currentDocument.annotation(id: annotationID) != nil else { return nil }
        return currentDocument.source
    }
}
