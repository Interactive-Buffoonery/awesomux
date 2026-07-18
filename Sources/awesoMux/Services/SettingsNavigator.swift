import Foundation
import Observation

/// In-window settings deep link: a pane sets the pending target, the
/// settings root consumes `pendingSection` to switch panes, and the
/// destination pane consumes `pendingScrollAnchor` to scroll a specific
/// section into view.
@MainActor
@Observable
final class SettingsNavigator {
    var pendingSection: SettingsSectionID?
    var pendingScrollAnchor: String?

    /// Anchors whose target views are currently in the view tree. A pending
    /// scroll anchor is only consumed once its target is mounted; consuming
    /// earlier would no-op the scroll and silently lose the deep link.
    private(set) var mountedAnchors: Set<String> = []

    func anchorDidMount(_ anchor: String) {
        mountedAnchors.insert(anchor)
    }

    func anchorDidUnmount(_ anchor: String) {
        mountedAnchors.remove(anchor)
    }
}
