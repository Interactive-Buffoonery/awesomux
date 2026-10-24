import AppKit
import DesignSystem
import SwiftUI

struct CodexPaneStatusNote: View {
    @State private var isExpanded = false

    private let alias = "alias codex='codex --no-daemon'"

    static var summary: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
            Text(
                .init(
                    String(
                        localized: "For the most accurate status in each pane, start Codex with `codex --no-daemon`.",
                        comment: "Codex pane status advice. Preserve the command in backticks."
                    ))
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .awFont(AwFont.UI.meta)
        .foregroundStyle(Color.aw.text3)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    String(
                        localized:
                            "Codex now runs agents in one shared background server, so awesoMux can't always tell which pane an update came from. Panes on the shared server still show status from what's on screen, just less precisely.",
                        comment: "Explains Codex shared-server pane status limitations."
                    ))
                AgentActionFlowLayout {
                    Text(verbatim: alias)
                        .awFont(AwFont.Mono.meta)
                        .textSelection(.enabled)
                    Button(action: copyAlias) {
                        Label(String(localized: "Copy Alias"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(String(localized: "Copy Alias"))
                    .accessibilityHint(String(localized: "Copy the Codex no-daemon alias to the clipboard."))
                }
                bullet(String(localized: "`codex agents` and remote control need the shared server."))
                bullet(String(localized: "A session may stop when its terminal closes."))
                bullet(String(localized: "Turning off auto-start in Codex's config isn't enough on its own."))
            }
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            Text(String(localized: "Why this matters", comment: "Codex shared-server explanation disclosure."))
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "•").accessibilityHidden(true)
            Text(.init(text))
        }
        .accessibilityElement(children: .combine)
    }

    private func copyAlias() {
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString(alias, forType: .string)
        TerminalAccessibilityAnnouncer.announce(
            didCopy
                ? String(localized: "Alias copied.", comment: "Codex alias copy success announcement.")
                : String(localized: "Could not copy the alias.", comment: "Codex alias copy failure announcement.")
        )
    }
}
