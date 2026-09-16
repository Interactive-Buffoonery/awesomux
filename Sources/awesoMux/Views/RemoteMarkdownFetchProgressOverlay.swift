import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Document-origin in-flight chrome for a remote Markdown fetch.
///
/// Overlay only — never a `DocumentPane`, never a remount identity. Hit-testing
/// stays off so compose-guard and scroll are not fighting a placeholder tab.
///
/// The dim layer is hidden from accessibility; `ProgressView` keeps its role
/// and the unified loading label. Do not wrap this in
/// `accessibilityElement(children: .ignore)` — that collapses the progress role.
struct RemoteMarkdownFetchProgressOverlay: View {
    var body: some View {
        ZStack {
            Color.aw.surface.chrome.opacity(0.45)
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel(
                    TerminalAccessibilityAnnouncer.remoteMarkdownLoadingAnnouncement
                )
        }
        .allowsHitTesting(false)
    }
}

/// Owns the progress-coordinator environment read so `DocumentGroupView`
/// body does not track the waiters map. Overlay shows only when the selected
/// tab's remote identity is in flight with document origin (fetch identity or
/// source pin).
struct RemoteMarkdownFetchProgressOverlayHost: View {
    let sessionID: TerminalSession.ID
    let identity: ResourceIdentity?

    @Environment(RemoteMarkdownFetchProgressCoordinator.self)
    private var progress: RemoteMarkdownFetchProgressCoordinator?

    var body: some View {
        if let identity,
            let progress,
            progress.documentOverlayKeys.contains(
                RemoteMarkdownFetchProgressCoordinator.Key(
                    sessionID: sessionID,
                    identity: identity
                )
            )
        {
            RemoteMarkdownFetchProgressOverlay()
        }
    }
}
