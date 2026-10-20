import DesignSystem
import SwiftUI

/// Keeps disclosure interaction separate from the provider's enable switch.
struct AgentIntegrationDisclosureRow<Status: View, EnableToggle: View, Content: View>: View {
    let title: String
    let subtitle: String
    let needsAttention: Bool
    let enabledSetupCount: Int
    @ViewBuilder var status: Status
    @ViewBuilder var toggle: EnableToggle
    @ViewBuilder var content: Content

    // Latch attention so clearing a problem mid-edit never collapses the field
    // being edited. A manual expansion choice wins for this pane.
    @State private var expansionChoice: Bool?
    @State private var attentionExpanded = false

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expansionChoice ?? attentionExpanded },
                set: { expansionChoice = $0 }
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if enabledSetupCount > 0 {
                    Text(
                        String.localizedStringWithFormat(
                            String(
                                localized: "Used by %lld enabled launch setups.", comment: "Enabled launch setups sharing an integration."),
                            Int64(enabledSetupCount)
                        )
                    )
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
                }
                content
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                    Text(subtitle)
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text3)
                }
                Spacer(minLength: 12)
            }
        }
        .disclosureGroupStyle(AgentIntegrationDisclosureStyle(status: status, toggle: toggle))
        .padding(14)
        .onChange(of: needsAttention, initial: true) { _, needsAttention in
            if needsAttention { attentionExpanded = true }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AgentIntegrationDisclosureStyle<Status: View, EnableToggle: View>: DisclosureGroupStyle {
    let status: Status
    let toggle: EnableToggle

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                            .awFont(AwFont.UI.meta)
                            .foregroundStyle(Color.aw.text3)
                            .frame(width: 10)
                            .accessibilityHidden(true)
                        configuration.label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    configuration.isExpanded
                        ? String(localized: "Expanded", comment: "Disclosure state.")
                        : String(localized: "Collapsed", comment: "Disclosure state."))
                status
                toggle
            }
            if configuration.isExpanded {
                configuration.content
                    .disclosureGroupStyle(.automatic)
                    .padding(.leading, 20)
            }
        }
    }
}
