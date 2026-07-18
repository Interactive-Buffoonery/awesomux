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
    private(set) var pendingAccessibilityFocusAnchor: String?
    private var pendingAnalyticsDiagnosticsSection: AnalyticsDiagnosticsSection?

    /// Anchors whose target views are currently in the view tree. A pending
    /// scroll anchor is only consumed once its target is mounted; consuming
    /// earlier would no-op the scroll and silently lose the deep link.
    private(set) var mountedAnchors: Set<String> = []

    func noteAnalyticsDiagnosticsIntent(_ section: AnalyticsDiagnosticsSection) {
        pendingAnalyticsDiagnosticsSection = section
    }

    func consumeAnalyticsDiagnosticsIntent() -> AnalyticsDiagnosticsSection {
        defer { pendingAnalyticsDiagnosticsSection = nil }
        return pendingAnalyticsDiagnosticsSection ?? .overview
    }

    func anchorDidMount(_ anchor: String) {
        mountedAnchors.insert(anchor)
    }

    func anchorDidUnmount(_ anchor: String) {
        mountedAnchors.remove(anchor)
    }

    /// Carries explicit deep-link intent from the shell's successful scroll to
    /// the mounted destination. The destination consumes this separately so a
    /// visual scroll cannot leave VoiceOver at the source control.
    func scrollDidLand(on anchor: String) {
        pendingAccessibilityFocusAnchor = anchor
    }

    func consumeAccessibilityFocus(for anchor: String) -> Bool {
        guard pendingAccessibilityFocusAnchor == anchor else { return false }
        pendingAccessibilityFocusAnchor = nil
        return true
    }
}
