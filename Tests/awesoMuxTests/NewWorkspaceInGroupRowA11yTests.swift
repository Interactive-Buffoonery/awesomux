import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

/// Two WCAG-shaped regressions this row shipped with, both invisible to a
/// green suite: a pointer target under the 24x24 minimum, and an accessibility
/// name repeated verbatim in every expanded group, so the VoiceOver rotor
/// listed N indistinguishable items.
@Suite("New workspace in group row accessibility")
@MainActor
struct NewWorkspaceInGroupRowA11yTests {
    /// The remove control draws a 9pt glyph; what must clear 24x24 is the
    /// *target*. The row reserves matching space beside it so the two controls
    /// cannot overlap, so assert one constant governs both — a mismatch
    /// between them is exactly how the overlap returns.
    @Test("the remove control's pointer target clears the 24x24 minimum")
    func removeTargetMeetsMinimumSize() {
        #expect(NewWorkspaceInGroupRow.removeTargetSize >= 24)
    }

    /// Calls the row's OWN label builder rather than re-deriving the string in
    /// the test — an oracle that constructs the same text the view constructs
    /// would pass even if the view ignored `groupName` entirely.
    ///
    /// **Coverage limit.** This pins the label the row produces, not the label
    /// VoiceOver ultimately reads. A rendered readback was attempted first and
    /// is not reachable: hosting this row through `SidebarHostedTestHarness`
    /// exposes an empty accessibility tree, so the wiring between
    /// `accessibilityLabel(forGroupNamed:)` and the `.accessibilityLabel`
    /// modifier is unverified here and rests on review.
    @Test("each group's create row builds a distinguishable accessibility name")
    func createRowNamesAreDistinctPerGroup() {
        let alpha = NewWorkspaceInGroupRow.accessibilityLabel(forGroupNamed: "Alpha")
        let beta = NewWorkspaceInGroupRow.accessibilityLabel(forGroupNamed: "Beta")

        #expect(alpha != beta, "both groups produced \(alpha)")
        #expect(alpha.contains("Alpha"))
        #expect(beta.contains("Beta"))
    }
}
