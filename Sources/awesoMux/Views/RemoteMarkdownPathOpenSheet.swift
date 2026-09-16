import AwesoMuxCore
import SwiftUI

/// Typed absolute/`~/` path sheet for opening a remote Markdown snapshot.
/// V0 has no directory browse — users paste or type a path ending in
/// `.md` / `.markdown`.
struct RemoteMarkdownPathOpenSheet: View {
    let target: RemoteTarget
    let onCancel: () -> Void
    let onOpen: (String) -> Void

    @State private var draftPath = ""
    @FocusState private var isPathFocused: Bool

    var body: some View {
        let normalizedPath = Self.normalizedSupportedPath(draftPath)
        let trimmedPath = draftPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let openDisabledHint = Self.openDisabledAccessibilityHint(forDraft: draftPath)
        VStack(alignment: .leading, spacing: 16) {
            Text(
                String(
                    localized: "Open Remote Markdown",
                    comment: "Title for the typed-path sheet that opens a remote Markdown file over SSH"
                )
            )
            .font(.headline)
            .accessibilityAddTraits(.isHeader)

            Text(
                String(
                    localized: "Opens a read-only snapshot from \(target.sshDestination).",
                    comment:
                        "Caption under the remote Markdown path sheet title; placeholder is the declared SSH destination"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                String(
                    localized: "Remote path",
                    comment: "Label for the remote Markdown absolute or ~/ path field"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField(Self.pathPlaceholder, text: $draftPath)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isPathFocused)
                .accessibilityLabel(
                    String(
                        localized: "Remote Markdown path",
                        comment: "Accessibility label for the remote Markdown typed-path field"
                    )
                )
                .accessibilityHint(
                    String(
                        localized:
                            "Enter an absolute path or a path starting with ~/ that ends in .md or .markdown.",
                        comment: "Accessibility hint for the remote Markdown typed-path field"
                    )
                )
                .onSubmit { submit(normalizedPath) }

            if !trimmedPath.isEmpty, normalizedPath == nil {
                Text(
                    String(
                        localized:
                            "Enter an absolute /… or ~/… path ending in .md or .markdown.",
                        comment:
                            "Validation caption when the remote Markdown typed path is unsupported"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open") {
                    submit(normalizedPath)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedPath == nil)
                .accessibilityHint(openDisabledHint ?? "", isEnabled: openDisabledHint != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                localized: "Open Remote Markdown",
                comment: "Title for the typed-path sheet that opens a remote Markdown file over SSH"
            )
        )
        .onAppear { isPathFocused = true }
    }

    private static let pathPlaceholder = String(
        localized: "/absolute/path/file.md or ~/path/file.md",
        comment: "Placeholder example for the remote Markdown typed-path field"
    )

    static func normalizedSupportedPath(_ draft: String) -> String? {
        RemoteMarkdownReference.normalizedTypedPath(draft)
    }

    /// Why the Open button is disabled, for VoiceOver. Empty field gets an
    /// enablement hint; a non-empty unsupported path reuses the visual caption.
    static func openDisabledAccessibilityHint(forDraft draft: String) -> String? {
        guard normalizedSupportedPath(draft) == nil else { return nil }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                localized: "Enter a remote Markdown path to enable Open",
                comment:
                    "Accessibility hint for the disabled Open button when the remote Markdown path field is empty"
            )
        }
        return String(
            localized: "Enter an absolute /… or ~/… path ending in .md or .markdown.",
            comment: "Validation caption when the remote Markdown typed path is unsupported"
        )
    }

    private func submit(_ path: String?) {
        guard let path else { return }
        onOpen(path)
    }
}
