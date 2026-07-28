import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing

@testable import awesoMux

/// A WCAG-shaped regression this row shipped with, invisible to a green
/// suite: an accessibility name repeated verbatim in every expanded group, so
/// the VoiceOver rotor listed N indistinguishable items.
///
/// The row's own 24pt pointer-target guard moved rather than vanished when the
/// remove X it used to reserve space for was deleted: the ROW is the target
/// now, so `SidebarGroupDropRegionTests` asserts its measured height from live
/// geometry. `SidebarGroupHeaderHitTargetTests.closeTargetMeetsMinimumSize`
/// covers the group-close X in its new (and only) home, the group header.
@Suite("New workspace in group row accessibility")
@MainActor
struct NewWorkspaceInGroupRowA11yTests {
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
