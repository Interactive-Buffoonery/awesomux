import AppKit
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

@MainActor
final class DocumentReloadCompletion {
    private var completedGeneration = 0
    private var waiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait(for generation: Int) async {
        guard completedGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            waiters.append((generation, continuation))
        }
    }

    func complete(_ generation: Int) {
        completedGeneration = max(completedGeneration, generation)
        let completed = waiters.filter { $0.generation <= completedGeneration }
        waiters.removeAll { $0.generation <= completedGeneration }
        completed.forEach { $0.continuation.resume() }
    }

    func completeAll() {
        waiters.forEach { $0.continuation.resume() }
        waiters.removeAll()
    }
}

enum AnnotationPopoverLifecycle {
    static func behavior(isSubmitting: Bool) -> NSPopover.Behavior {
        isSubmitting ? .applicationDefined : .transient
    }
}

enum AnnotationSaveRecovery {
    static func canSubmitNewAnnotation(
        hasValidDraft: Bool,
        isSubmitting: Bool,
        outcome: AnnotationSaveOutcome?
    ) -> Bool {
        hasValidDraft && !isSubmitting && outcome != .copyAndReselect
    }

    static func canRebind(
        annotationID: String,
        openedDocument: RenderedDocument,
        currentDocument: RenderedDocument?
    ) -> Bool {
        guard let currentDocument else { return false }

        return currentDocument.annotation(id: annotationID)
            == openedDocument.annotation(id: annotationID)
    }

    static func announcement(for outcome: AnnotationSaveOutcome) -> String? {
        switch outcome {
        case .reloadAndRetry:
            "The document changed. Reload complete. Try saving again."
        case .copyAndReselect:
            "The selection changed. Copy the draft and select the text again."
        case .copyOnly:
            "The annotation changed or was removed. Copy the draft before closing."
        case .failed:
            "The draft was not saved."
        case .saved:
            nil
        }
    }

    static func copyAnnouncement(didCopy: Bool) -> String {
        didCopy ? "Draft copied" : "Draft could not be copied"
    }

    @MainActor
    static func announce(_ outcome: AnnotationSaveOutcome) {
        if let message = announcement(for: outcome) {
            TerminalAccessibilityAnnouncer.announce(message)
        }
    }

    @MainActor
    static func copyDraft(_ draft: String) {
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString(draft, forType: .string)
        TerminalAccessibilityAnnouncer.announce(copyAnnouncement(didCopy: didCopy))
    }
}
