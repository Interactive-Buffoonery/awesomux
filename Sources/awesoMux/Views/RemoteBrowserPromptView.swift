import Foundation
import DesignSystem
import Observation
import SwiftUI

@MainActor
@Observable
final class RemoteBrowserPromptChoice {
    var remember = false
}

struct RemoteBrowserPromptView: View {
    let source: String
    let url: URL
    let warning: String?
    @Bindable var choice: RemoteBrowserPromptChoice
    let canRemember: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(url.host ?? "")
                    .awFont(AwFont.UI.title)
                    .textSelection(.enabled)
                Text(url.absoluteString)
                    .awFont(AwFont.Mono.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning {
                    Text(warning)
                        .awFont(AwFont.UI.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canRemember {
                    Toggle(
                        String(
                            localized: "Always allow \(source) to open links to \(url.host ?? "")",
                            comment: "Remember a browser permission; first argument is the SSH destination, second is the website hostname"
                        ),
                        isOn: $choice.remember
                    )
                    .awFont(AwFont.UI.body)
                    Text(
                        String(
                            localized:
                                "Only this website, HTTP or HTTPS, and port are allowed. Change it in Settings → Workspaces → Managed SSH.",
                            comment:
                                "Explanation that a saved browser permission covers only the exact website origin and where to revoke it"
                        )
                    )
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
    }
}
