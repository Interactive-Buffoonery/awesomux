import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct RemoteAdditionalSSHFeaturesSheet: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var rememberChoice = false
    @State private var saveError: String?

    let request: RemoteAdditionalSSHFeaturesSheetPresenter.Request
    let onContinue: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                String(
                    localized: "Enable additional SSH features on \(request.destination)?",
                    comment: "Remote helper setup title. Argument is the declared SSH destination."
                )
            )
            .awFont(AwFont.UI.title)
            .foregroundStyle(Color.aw.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

            RemoteAdditionalSSHFeaturesView(
                destination: request.destination,
                platform: request.platform,
                installPath: request.installPath
            )

            Toggle("Remember this choice for all hosts", isOn: $rememberChoice)
                .toggleStyle(.checkbox)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(Color.aw.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 12)

                Button(
                    rememberChoice
                        ? String(localized: "Never Ask", comment: "Remember declining remote helper installation")
                        : String(
                            localized: "Continue Without Helper",
                            comment: "Decline remote helper setup while continuing the SSH connection"
                        ),
                    action: { choose(install: false) }
                )
                .buttonStyle(.bordered)
                .tint(Color.aw.text3)
                .foregroundStyle(Color.aw.text)
                .keyboardShortcut(.cancelAction)

                Button(action: { choose(install: true) }) {
                    Text(confirmTitle)
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.surface.chrome)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.aw.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .background(Color.aw.surface.chrome)
        .interactiveDismissDisabled(true)
        .accessibilityElement(children: .contain)
    }

    private func choose(install: Bool) {
        saveError = nil
        if rememberChoice {
            saveError = Self.remember(install: install, store: appSettingsStore)
            if saveError != nil {
                TerminalAccessibilityAnnouncer.announceSettingsError(saveError)
                return
            }
        }
        if install { onInstall() } else { onContinue() }
    }

    @MainActor
    static func remember(install: Bool, store: AppSettingsStore) -> String? {
        if let reason = ManagedSSHPreferenceWriteGuard.blockedReason(store: store) { return reason }
        let policy: WorkspaceConfig.RemoteHelperInstallPolicy = install ? .alwaysInstall : .neverAsk
        store.workspaces.update { $0.remoteHelperInstallPolicy = policy }
        guard store.workspaces.value.remoteHelperInstallPolicy == policy else {
            return store.latestError?.displayText
                ?? String(localized: "Couldn’t save the remote helper setting.", comment: "Remote helper preference save error")
        }
        return nil
    }

    private var confirmTitle: String {
        if rememberChoice {
            return String(localized: "Always Install", comment: "Remember approving remote helper installation")
        }
        return switch request.action {
        case .install:
            String(localized: "Install Helper", comment: "Approve remote helper installation button")
        case .update:
            String(localized: "Update Helper", comment: "Approve remote helper update button")
        }
    }
}
