import AwesoMuxCore
import SwiftUI

enum SSHWorkspaceDestinationValidation {
    static func target(from text: String) -> RemoteTarget? {
        guard let target = RemoteTarget(parsing: text), target.isSafeSSHDestination else { return nil }
        return target
    }
}

struct SSHWorkspaceConnectSheet: View {
    let groupName: String
    let onCancel: () -> Void
    let onConnect: (RemoteTarget) -> Void

    @State private var destination = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let parsedTarget = RemoteTarget(parsing: destination)
        let target = SSHWorkspaceDestinationValidation.target(from: destination)
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect via SSH")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("my-server", text: $destination)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isFocused)
                .accessibilityLabel("SSH destination")
                .onSubmit { if let target { onConnect(target) } }
            if parsedTarget != nil, target == nil {
                Text("Enter an SSH alias, hostname, or user@host, not a command option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Invalid SSH destination")
            }
            Text("Creates a managed SSH workspace in “\(groupName).”\nOpenSSH will use your existing config and credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let target { onConnect(target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect via SSH")
        .onAppear { isFocused = true }
    }
}
