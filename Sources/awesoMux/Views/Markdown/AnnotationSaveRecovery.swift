import AppKit
import AwesoMuxCore

enum AnnotationSaveOutcome: Equatable, Sendable {
    case saved
    case reloadAndRetry
    case copyAndReselect
    case copyOnly
    /// The file grew past `DocumentURLValidator.maxFileSizeBytes` while this
    /// editor was open, so the viewer is holding a render the disk no longer
    /// matches and no write can be committed against it.
    ///
    /// Terminal on BOTH submit gates below, unlike `copyOnly` (terminal only
    /// for an existing annotation) and `copyAndReselect` (terminal only for a
    /// new one). It has to be: the popovers are `NSHostingController` root
    /// views handed over imperatively, so an editor opened before the file
    /// crossed the cap never re-renders and would otherwise keep offering a
    /// Save that re-reads, re-rejects, and invites another attempt.
    case oversizeCopyOnly
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
    private(set) var isInvalidated = false
    private var waiters: [(generation: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    func wait(for generation: Int) async -> Bool {
        guard !isInvalidated else { return false }
        guard completedGeneration < generation else { return true }
        return await withCheckedContinuation { continuation in
            waiters.append((generation, continuation))
        }
    }

    func complete(_ generation: Int) {
        completedGeneration = max(completedGeneration, generation)
        let completed = waiters.filter { $0.generation <= completedGeneration }
        waiters.removeAll { $0.generation <= completedGeneration }
        completed.forEach { $0.continuation.resume(returning: true) }
    }

    func invalidate() {
        isInvalidated = true
        waiters.forEach { $0.continuation.resume(returning: false) }
        waiters.removeAll()
    }
}

enum AnnotationPopoverLifecycle {
    static func behavior(isSubmitting: Bool) -> NSPopover.Behavior {
        isSubmitting ? .applicationDefined : .transient
    }
}

enum AnnotationSaveRecovery {
    /// One sentence for every surface that can hit the size cap mid-edit —
    /// both popovers, the note sheet, and the VoiceOver announcement — so the
    /// four cannot drift, and so the cap is read from the validator rather
    /// than restated.
    static let oversizeMessage = String(
        localized:
            "The file has grown past the \(DocumentURLValidator.maxFileSizeMegabytes) MB limit, so it can't be edited until it fits again.",
        comment: "Annotation save recovery message when the document outgrew the size cap; the placeholder is the cap in whole megabytes"
    )

    static func outcome(
        afterReloading result: MarkdownDocumentCommitResult,
        conflictOutcome: AnnotationSaveOutcome
    ) -> AnnotationSaveOutcome? {
        switch result {
        case .observedConflict:
            conflictOutcome
        case .inputTooLarge:
            .oversizeCopyOnly
        case .committed, .unreadable, .invalidEdit, .outputTooLarge, .failed:
            nil
        }
    }

    /// The parked outcome after the document's editability changes under an
    /// open sheet.
    ///
    /// `.oversizeCopyOnly` suspends submission rather than reporting a failure,
    /// so it is the one outcome that has to be *withdrawn* when the cause goes
    /// away — the file fitting again is exactly that. Nothing else clears it,
    /// and it is the only thing still disabling Submit, so leaving it set
    /// strands a draft that would now save perfectly well. Every other outcome
    /// records something that really happened and survives untouched.
    static func recovery(
        afterEditingAllowed allowsEditing: Bool,
        isEditing: Bool,
        current: AnnotationSaveOutcome?
    ) -> AnnotationSaveOutcome? {
        guard allowsEditing else {
            return isEditing ? .oversizeCopyOnly : current
        }
        return current == .oversizeCopyOnly ? nil : current
    }

    static func canSubmitExistingAnnotation(
        isSubmitting: Bool,
        outcome: AnnotationSaveOutcome?
    ) -> Bool {
        !isSubmitting && outcome != .copyOnly && outcome != .oversizeCopyOnly
    }

    static func canSubmitNewAnnotation(
        hasValidDraft: Bool,
        isSubmitting: Bool,
        outcome: AnnotationSaveOutcome?
    ) -> Bool {
        hasValidDraft && !isSubmitting && outcome != .copyAndReselect
            && outcome != .oversizeCopyOnly
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

    static func snapshotForNewDocumentNote(
        openedSnapshot: MarkdownDocumentSnapshot,
        currentSnapshot: MarkdownDocumentSnapshot?,
        currentDocument: RenderedDocument?
    ) -> MarkdownDocumentSnapshot? {
        guard let currentSnapshot else { return nil }
        if currentSnapshot == openedSnapshot { return openedSnapshot }
        guard let currentDocument, currentDocument.documentNote == nil else { return nil }
        return currentSnapshot
    }

    static func announcement(
        for outcome: AnnotationSaveOutcome,
        hasRecoverableDraft: Bool = true
    ) -> String? {
        switch outcome {
        case .reloadAndRetry:
            String(
                localized: "The document changed. Reload complete. Try saving again.",
                comment: "Save recovery announcement after reloading a changed document")
        case .copyAndReselect:
            String(
                localized: "The selection changed. Copy the draft and select the text again.",
                comment: "Save recovery announcement for a stale text selection")
        case .copyOnly:
            hasRecoverableDraft
                ? String(
                    localized: "The annotation changed or was removed. Copy the draft before closing.",
                    comment: "Save recovery announcement when an annotation draft can be copied")
                : String(
                    localized: "The annotation changed or was removed.",
                    comment: "Save recovery announcement when an annotation no longer exists")
        case .oversizeCopyOnly:
            oversizeMessage
        case .failed:
            String(localized: "The draft was not saved.", comment: "Save failure announcement")
        case .saved:
            nil
        }
    }

    static func copyAnnouncement(didCopy: Bool) -> String {
        didCopy
            ? String(localized: "Draft copied", comment: "Draft copy success announcement")
            : String(localized: "Draft could not be copied", comment: "Draft copy failure announcement")
    }

    @MainActor
    static func announce(
        _ outcome: AnnotationSaveOutcome,
        hasRecoverableDraft: Bool = true
    ) {
        if let message = announcement(
            for: outcome,
            hasRecoverableDraft: hasRecoverableDraft
        ) {
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
