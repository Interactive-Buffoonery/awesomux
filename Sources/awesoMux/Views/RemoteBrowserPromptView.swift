import Foundation
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
                    .font(.headline)
                    .textSelection(.enabled)
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning {
                    Text(warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canRemember {
                    Toggle(
                        String(localized: "Always allow \(source) to open links to \(url.host ?? "")"),
                        isOn: $choice.remember
                    )
                    Text("Only this website, HTTP or HTTPS, and port are allowed. Change it in Settings → Workspaces → Managed SSH.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
    }
}
