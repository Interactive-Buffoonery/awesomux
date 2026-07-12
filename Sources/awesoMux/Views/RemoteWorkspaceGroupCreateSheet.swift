import AwesoMuxCore
import SwiftUI

struct RemoteWorkspaceGroupCreateSheet: View {
    let onCancel: () -> Void
    let onCreate: (_ name: String, _ target: RemoteTarget) -> Void

    @State private var draftName = ""
    @State private var draftHost = ""
    @FocusState private var isHostFocused: Bool

    var body: some View {
        let target = RemoteTarget(parsing: draftHost)
        let canCreate = target != nil

        return VStack(alignment: .leading, spacing: 16) {
            Text("New Remote Workspace Group")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Group name (optional)", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .accessibilityLabel("Workspace group name")
                .onSubmit { submit(target: target, canCreate: canCreate) }

            Text("Host")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("user@host", text: $draftHost)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isHostFocused)
                .accessibilityLabel("Remote host")
                .onSubmit { submit(target: target, canCreate: canCreate) }

            if let validation = validationMessage(target: target) {
                Text(validation)
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

                Button("Create") {
                    submit(target: target, canCreate: canCreate)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                // Conditional hint on one stable button identity — an if/else
                // over two button copies resets focus mid-edit.
                .accessibilityHint(
                    validationMessage(target: target)
                        ?? String(localized: "Enter a host to enable Create", comment: "Accessibility hint for the disabled Create button in the New Remote Workspace Group sheet"),
                    isEnabled: !canCreate
                )
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Remote Workspace Group")
        .onAppear {
            isHostFocused = true
        }
    }

    private func validationMessage(target: RemoteTarget?) -> String? {
        guard target == nil, !draftHost.isEmpty else {
            return nil
        }
        return String(
            localized: "Enter a host to connect to, like user@example.com.",
            comment: "Validation message when the remote workspace group's host field doesn't parse to a usable SSH target"
        )
    }

    private func submit(target: RemoteTarget?, canCreate: Bool) {
        guard canCreate, let target else {
            return
        }
        onCreate(draftName, target)
    }
}
