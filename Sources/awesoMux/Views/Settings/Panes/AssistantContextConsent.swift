import AwesoMuxLocalAPI
import SwiftUI

struct AssistantContextConsentRequest: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let connectionLabel: String
    let paneTitle: String
    let agent: LocalAPIAgent
}

struct AssistantContextConsent: View {
    @Environment(\.dismiss) private var dismiss
    @State private var allowTerminalHistory = false
    @AccessibilityFocusState private var errorIsFocused: Bool
    let request: AssistantContextConsentRequest
    let isWorking: Bool
    let errorMessage: String?
    let save: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Share Session Details"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(request.connectionLabel).font(.headline)
            Text(request.paneTitle)
            Text(request.agent.provider)
            Text(request.agent.providerSessionID ?? String(localized: "No session ID found"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                String(
                    format: String(
                        localized:
                            "%@ will be able to read up to 24 KB of this agent's conversation. It can include private text, commands, and tool output. Access ends if this pane restarts."
                    ), request.connectionLabel
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "The app may send these details to its assistant service."))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(String(localized: "Also share recent terminal output"), isOn: $allowTerminalHistory)
            Text(
                String(
                    localized:
                        "Terminal output can include anything printed in this pane, including by earlier programs. awesoMux never sends it in place of the conversation."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($errorIsFocused)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Share Details")) { save(allowTerminalHistory) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: errorMessage) { _, message in
            errorIsFocused = message != nil
        }
    }
}
