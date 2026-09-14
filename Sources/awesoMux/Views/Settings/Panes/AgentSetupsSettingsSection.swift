import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct AgentSetupsSettingsSection: View {
    @Environment(AgentSetupStore.self) private var store
    @State private var editing: AgentSetup?
    @State private var removing: AgentSetup?

    var body: some View {
        SettingsSection(
            index: 2,
            title: String(localized: "Agent setups"),
            subtitle: String(localized: "Named launch choices for the command palette. Status hooks are shared by provider.")
        ) {
            ForEach(Array(store.setups.enumerated()), id: \.element.id) { index, setup in
                let rowName = String(
                    format: String(localized: "%@, setup %@", comment: "Setup name and list position"), setup.name, String(index + 1))
                SettingsField(label: setup.name, hint: setup.provider.rawValue, isFirst: index == 0) {
                    HStack(spacing: 8) {
                        Toggle(
                            String(format: String(localized: "Enable %@", comment: "Enable named setup"), rowName),
                            isOn: Binding(
                                get: { store.setup(id: setup.id)?.enabled ?? false },
                                set: { enabled in
                                    guard var current = store.setup(id: setup.id) else { return }
                                    current.enabled = enabled
                                    store.save(current)
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(String(format: String(localized: "Enable %@", comment: "Enable named setup"), rowName))
                        Button(String(localized: "Edit…")) { editing = setup }
                            .accessibilityLabel(String(format: String(localized: "Edit %@", comment: "Edit named setup"), rowName))
                        Button {
                            store.move(id: setup.id, offset: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(String(format: String(localized: "Move %@ up", comment: "Move named setup up"), rowName))
                        Button {
                            store.move(id: setup.id, offset: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(index == store.setups.count - 1)
                        .accessibilityLabel(String(format: String(localized: "Move %@ down", comment: "Move named setup down"), rowName))
                        Button(String(localized: "Remove"), role: .destructive) { removing = setup }
                            .accessibilityLabel(String(format: String(localized: "Remove %@", comment: "Remove named setup"), rowName))
                    }
                    .buttonStyle(.bordered)
                }
            }
            SettingsField(
                label: String(localized: "New setup"),
                hint: String(
                    localized: "Use a wrapper executable for environment variables or credentials. Do not put secrets in arguments."),
                isFirst: store.setups.isEmpty
            ) {
                Button(String(localized: "Add Agent Setup…")) {
                    editing = AgentSetup(name: "", provider: .claudeCode, executablePath: "")
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(item: $editing) { setup in
            AgentSetupEditor(setup: setup) { draft in
                if store.save(draft) { editing = nil }
            }
        }
        .confirmationDialog(
            String(localized: "Remove agent setup?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { setup in
            Button(String(format: String(localized: "Remove %@", comment: "Remove named setup"), setup.name), role: .destructive) {
                store.remove(id: setup.id)
                removing = nil
            }
        } message: { _ in
            Text(String(localized: "This removes the launch choice. Shared status hooks are unchanged."))
        }
    }
}

private struct AgentSetupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var setup: AgentSetup
    let save: (AgentSetup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Agent setup"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Name"))
                            .font(.caption)
                            .accessibilityHidden(true)
                        TextField(String(localized: "Name"), text: $setup.name)
                            .accessibilityLabel(String(localized: "Name"))
                    }
                    Picker(String(localized: "Provider"), selection: $setup.provider) {
                        ForEach(AgentSetup.providers, id: \.self) { provider in
                            Text(verbatim: provider.rawValue).tag(provider)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Executable path"))
                            .font(.caption)
                            .accessibilityHidden(true)
                        TextField(
                            String(localized: "Executable path"), text: $setup.executablePath, prompt: Text("/absolute/path/to/agent")
                        )
                        .accessibilityLabel(String(localized: "Executable path"))
                        .autocorrectionDisabled()
                    }
                    Text(String(localized: "Absolute paths only. Shell aliases and expansions are not supported."))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(setup.arguments.indices, id: \.self) { index in
                        let argumentLabel = String(
                            format: String(localized: "Argument %@", comment: "Argument position"), String(index + 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(argumentLabel)
                                .font(.caption)
                                .accessibilityHidden(true)
                            HStack {
                                TextField(argumentLabel, text: $setup.arguments[index])
                                    .accessibilityLabel(argumentLabel)
                                    .autocorrectionDisabled()
                                Button {
                                    setup.arguments.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel(
                                    String(
                                        format: String(localized: "Remove argument %@", comment: "Remove argument at position"),
                                        String(index + 1)))
                            }
                        }
                    }
                    Button(String(localized: "Add Argument")) { setup.arguments.append("") }
                    Text(
                        String(
                            localized:
                                "Each field is one literal argument, including spaces. Leave an argument field empty to pass an empty argument."
                        )
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            }
            .frame(maxHeight: 360)
            if let error = setup.validationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save(setup) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.validationError != nil)
                    .accessibilityHint(setup.validationError ?? "", isEnabled: setup.validationError != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
