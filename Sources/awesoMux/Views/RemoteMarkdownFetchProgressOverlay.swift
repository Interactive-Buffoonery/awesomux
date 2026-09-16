import DesignSystem
import SwiftUI

/// Document-origin in-flight chrome for a remote Markdown fetch.
///
/// Overlay only — never a `DocumentPane`, never a remount identity. Hit-testing
/// stays off so compose-guard and scroll are not fighting a placeholder tab.
struct RemoteMarkdownFetchProgressOverlay: View {
    var body: some View {
        ZStack {
            Color.aw.surface.chrome.opacity(0.45)
            ProgressView()
                .controlSize(.regular)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TerminalAccessibilityAnnouncer.remoteMarkdownLoadingAnnouncement)
    }
}
