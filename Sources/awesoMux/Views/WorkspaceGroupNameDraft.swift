import AwesoMuxCore
import Foundation
import UnicodeHygiene

struct WorkspaceGroupNameDraft {
    let typedName: String
    let sanitizedName: String
    let isDuplicate: Bool
    let isMixedScript: Bool

    init(typedName: String, existingGroupNames: some Sequence<String>) {
        let sanitizedName = SessionStore.sanitizedGroupName(typedName)
        self.typedName = typedName
        self.sanitizedName = sanitizedName
        isMixedScript = UnicodeHygiene.hasSuspiciousScriptMixing(typedName)
        isDuplicate = existingGroupNames.contains { existingName in
            SessionStore.sanitizedGroupName(existingName)
                .caseInsensitiveCompare(sanitizedName) == .orderedSame
        }
    }

    var canSubmit: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
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

    var sanitizationFeedback: String? {
        guard canSubmit,
            !typedName.utf8.elementsEqual(sanitizedName.utf8)
        else {
            return nil
        }

        let isolatedSavedName = "\u{2068}\(sanitizedName)\u{2069}"
        return String(
            localized: "Some characters or spacing will be adjusted. This name will be saved as “\(isolatedSavedName)”.",
            comment:
                "Inline feedback in workspace group create and rename sheets. Argument is the exact saved group name, wrapped in bidi isolates."
        )
    }
}
