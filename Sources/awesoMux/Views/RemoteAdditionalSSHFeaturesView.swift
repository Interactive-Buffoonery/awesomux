import DesignSystem
import SwiftUI

struct RemoteAdditionalSSHFeaturesView: View {
    let destination: String
    let platform: String
    let installPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Installing the **awesoMux helper** adds:")
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text2)

            VStack(alignment: .leading, spacing: 10) {
                benefit(
                    title: String(
                        localized: "Command activity visible in the sidebar",
                        comment: "Benefit listed in the additional SSH features prompt"
                    ),
                    systemImage: "waveform.path.ecg"
                )
                benefit(
                    title: String(
                        localized: "File transfers via copy and paste",
                        comment: "Benefit listed in the additional SSH features prompt"
                    ),
                    systemImage: "arrow.down.doc"
                )
                benefit(
                    title: String(
                        localized: "Accurate remote close warnings",
                        comment: "Benefit listed in the additional SSH features prompt"
                    ),
                    systemImage: "checkmark.shield"
                )
            }

            VStack(spacing: 9) {
                detailRow(
                    label: String(localized: "Destination", comment: "Remote helper detail label"),
                    value: destination
                )
                detailRow(
                    label: String(localized: "Platform", comment: "Remote helper detail label"),
                    value: platform
                )
                detailRow(
                    label: String(localized: "Installs to", comment: "Remote helper detail label"),
                    value: installPath
                )
            }
            .padding(12)
            .background(Color.aw.surface.elevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.aw.green)
                Text(
                    String(
                        localized: "Runs as your user · No administrator access",
                        comment: "Remote helper setup trust note"
                    )
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
            }

            Link(
                String(localized: "Learn more", comment: "Remote helper setup documentation link"),
                destination: URL(
                    string: "https://github.com/Interactive-Buffoonery/awesomux/blob/main/docs/remote-linux-helper.md"
                )!
            )
            .awFont(AwFont.UI.meta)
        }
    }

    private func benefit(title: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(Color.aw.accent)
            Text(title)
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
            Spacer(minLength: 12)
            Text(value)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
