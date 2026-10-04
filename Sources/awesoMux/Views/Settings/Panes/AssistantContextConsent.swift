import AwesoMuxLocalAPI
import SwiftUI

struct AssistantContextConsentRequest: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let connectionLabel: String
    let agent: LocalAPIAgent
}

struct AssistantContextConsent: View {
    @Environment(\.dismiss) private var dismiss
    @State private var allowTerminalHistory = false
    let request: AssistantContextConsentRequest
    let isWorking: Bool
    let errorMessage: String?
    let save: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Share Session Context"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(request.connectionLabel).font(.headline)
            Text("\(request.agent.workspaceName) — \(request.agent.provider)")
            Text(request.agent.providerSessionID ?? String(localized: "No exact provider session identity"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                String(
                    localized:
                        "This connection may share up to 24 KiB of this session with its assistant service. Content may include private text, commands, or tool output. The grant expires when this exact target changes."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            Toggle(String(localized: "Also allow terminal history for this target"), isOn: $allowTerminalHistory)
            Text(
                String(
                    localized:
                        "Terminal history can include shell output and text from earlier programs. It is a separate source and is never used automatically when a transcript is unavailable."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Allow Context Sharing")) { save(allowTerminalHistory) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
