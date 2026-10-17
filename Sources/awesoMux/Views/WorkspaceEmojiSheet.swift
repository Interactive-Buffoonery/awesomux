import AppKit
import AwesoMuxCore
import SwiftUI

struct WorkspaceEmojiSheet: View {
    let title: String
    let onCancel: () -> Void
    let onSave: (String?) -> Void
    let canRemove: Bool
    @State private var draftEmoji: String
    @State private var pickerRequestID = 0
    @State private var emojiFieldFocused = false

    init(title: String, emoji: String?, onCancel: @escaping () -> Void, onSave: @escaping (String?) -> Void) {
        self.title = title
        self.onCancel = onCancel
        self.onSave = onSave
        canRemove = emoji != nil
        _draftEmoji = State(initialValue: emoji ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Emoji for '\(title)'", comment: "Heading of the workspace emoji editor; argument is the workspace name.")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HStack {
                WorkspaceEmojiField(
                    text: $draftEmoji,
                    pickerRequestID: pickerRequestID,
                    onSubmit: save,
                    onCancel: onCancel,
                    isFocused: $emojiFieldFocused
                )
                .frame(width: 64, height: 36)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(emojiFieldFocused ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if draftEmoji.isEmpty {
                        Text("Emoji", comment: "Placeholder for a single workspace emoji.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }

                Button(String(localized: "Choose Emoji…", comment: "Opens the macOS character panel to choose a workspace emoji.")) {
                    pickerRequestID += 1
                }
            }

            Text("Choose or paste a single emoji.", comment: "Instruction in the workspace emoji editor.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isDraftInvalid {
                Text("Enter one emoji to enable Save.", comment: "Validation feedback for an invalid workspace emoji.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if canRemove {
                    Button(String(localized: "Remove Emoji", comment: "Clears the workspace emoji badge.")) { onSave(nil) }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityHint(
                        String(
                            localized: "Enter one emoji, or clear the field to remove the current emoji.",
                            comment: "Explains how to save or remove the workspace emoji using the keyboard."))
            }
        }
        .padding(20)
        .frame(width: 400)
        .onChange(of: isDraftInvalid) { _, invalid in
            if invalid {
                TerminalAccessibilityAnnouncer.announce(
                    String(localized: "Enter one emoji to enable Save.", comment: "Validation feedback for an invalid workspace emoji.")
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Set Workspace Emoji", comment: "Accessible name of the workspace emoji editor."))
    }

    private func save() {
        guard canSave else { return }
        onSave(WorkspaceEmoji.validated(draftEmoji))
    }

    private var canSave: Bool {
        WorkspaceEmoji.validated(draftEmoji) != nil || (canRemove && isDraftEmpty)
    }

    private var isDraftInvalid: Bool {
        !isDraftEmpty && WorkspaceEmoji.validated(draftEmoji) == nil
    }

    private var isDraftEmpty: Bool {
        draftEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
