import DesignSystem
import SwiftUI

struct RemoteAdditionalSSHFeaturesSheet: View {
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

            HStack(spacing: 10) {
                Spacer(minLength: 12)

                Button(
                    String(
                        localized: "Continue Without Helper",
                        comment: "Decline remote helper setup while continuing the SSH connection"
                    ),
                    action: onContinue
                )
                .buttonStyle(.bordered)
                .tint(Color.aw.text3)
                .foregroundStyle(Color.aw.text)
                .keyboardShortcut(.cancelAction)

                Button(action: onInstall) {
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

    private var confirmTitle: String {
        switch request.action {
        case .install:
            String(localized: "Install Helper", comment: "Approve remote helper installation button")
        case .update:
            String(localized: "Update Helper", comment: "Approve remote helper update button")
        }
    }
}
