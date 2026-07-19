import SwiftUI

struct WorkspaceGroupNameFeedback: View {
    let draft: WorkspaceGroupNameDraft

    var body: some View {
        if let validation = draft.validationMessage {
            Text(validation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let feedback = draft.visualSanitizationFeedback {
            Label(feedback, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
