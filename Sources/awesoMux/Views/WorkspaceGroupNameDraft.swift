import AwesoMuxCore
import Foundation
import UnicodeHygiene

struct WorkspaceGroupNameDraft {
    /// Scalar ceiling on input reaching the mixed-script scan, which is
    /// unbounded by design so the bridge permission prompt can see a spoof
    /// anywhere in its payload. This draft is the one caller that runs it per
    /// keystroke, so it bounds its own input rather than capping the shared
    /// predicate.
    ///
    /// Matched to the bound `UnicodeHygiene.sanitize` already applies, so the
    /// clamp cannot discard anything sanitization would have kept: a shorter
    /// ceiling silently changed what got saved, because a paste of mostly
    /// zero-width characters trims down to real text that a tight clamp had
    /// already cut off.
    ///
    /// The match is on sanitization's *input* bound only. Its output can be
    /// larger, because NFKC expands: 80 clusters of a base plus 50 U+0344 fold
    /// to 4960 scalars in exactly 80 characters, and the 80-character clip
    /// keeps all of them. So a saved name fed back in as input — the rename
    /// sheet — is re-clamped, and that sheet clamps the name it compares
    /// against to match.
    static let inputScalarLimit = 4096

    static func clampedInput(_ input: String) -> String {
        String(input.unicodeScalars.prefix(inputScalarLimit))
    }

    let typedName: String
    let sanitizedName: String
    let isDuplicate: Bool
    let isMixedScript: Bool
    private let allowsEmptyName: Bool

    init(
        typedName: String,
        existingGroupNames: some Sequence<String>,
        allowsEmptyName: Bool = false
    ) {
        let typedName = Self.clampedInput(typedName)
        let sanitizedName = SessionStore.sanitizedGroupName(typedName)
        self.typedName = typedName
        self.sanitizedName = sanitizedName
        self.allowsEmptyName = allowsEmptyName
        isMixedScript = UnicodeHygiene.hasSuspiciousScriptMixing(typedName)
        isDuplicate =
            !sanitizedName.isEmpty
            && existingGroupNames.contains { existingName in
                SessionStore.sanitizedGroupName(existingName)
                    .caseInsensitiveCompare(sanitizedName) == .orderedSame
            }
    }

    var canSubmit: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
        if allowsEmptyName, typedName.isEmpty {
            return nil
        }

        if sanitizedName.isEmpty {
            return typedName.isEmpty
                ? "Enter a group name."
                : "Enter a visible group name."
        }

        if isMixedScript {
            return String(
                localized: "Mixing Latin with Cyrillic or Greek letters isn't allowed here — use one alphabet.",
                comment: "Validation message when a workspace group name mixes visually confusable alphabets"
            )
        }

        if isDuplicate {
            return "\"\(sanitizedName)\" already exists."
        }

        return nil
    }

    nonisolated var visualSanitizationFeedback: String? {
        guard let savedNameAdjustment else {
            return nil
        }

        return Self.sanitizationFeedback(for: "\u{2068}\(savedNameAdjustment)\u{2069}")
    }

    nonisolated var spokenSanitizationFeedback: String? {
        guard let savedNameAdjustment else {
            return nil
        }

        return Self.sanitizationFeedback(for: savedNameAdjustment)
    }

    private nonisolated var savedNameAdjustment: String? {
        guard canSubmit,
            !typedName.utf8.elementsEqual(sanitizedName.utf8)
        else {
            return nil
        }

        return sanitizedName
    }

    private nonisolated static func sanitizationFeedback(for savedName: String) -> String {
        String(
            localized: "Some characters or spacing will be adjusted. This name will be saved as “{savedName}”.",
            comment:
                "Visual or spoken feedback in workspace group create and rename sheets. Preserve {savedName}; visual callers replace it with the exact saved name wrapped in bidi isolates."
        )
        .replacingOccurrences(of: "{savedName}", with: savedName)
    }
}

@MainActor
final class WorkspaceGroupNameAdjustmentAnnouncementGate {
    private var hasAnnouncedCurrentEdit = false

    func editingChanged() {
        hasAnnouncedCurrentEdit = false
    }

    func announceIfNeeded(
        for draft: WorkspaceGroupNameDraft,
        announce: (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        guard !hasAnnouncedCurrentEdit,
            let message = draft.spokenSanitizationFeedback
        else {
            return
        }

        hasAnnouncedCurrentEdit = true
        announce(message)
    }
}
