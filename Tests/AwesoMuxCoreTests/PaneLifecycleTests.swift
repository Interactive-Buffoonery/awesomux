import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct PaneLifecycleTests {
    private func leaf() -> WorkspaceLeaf {
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "lc-\(UUID().uuidString).md"),
            title: "notes.md"
        )
        return .documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
    }

    @Test func visibilityDerivesFromMount() {
        #expect(PaneVisibility(isMounted: true) == .visible)
        #expect(PaneVisibility(isMounted: false) == .hidden)
    }

    @Test func lifecycleDefaultsToMountedActive() {
        let lifecycle = leaf().lifecycle()
        #expect(lifecycle.availability == .attached)
        #expect(lifecycle.visibility == .visible)
        #expect(lifecycle.closePhase == .active)
    }

    @Test func lifecycleComposesHiddenAndClosing() {
        // The vocabulary the availability classifier cannot emit is representable
        // through the other two axes.
        let lifecycle = leaf().lifecycle(isMounted: false, closePhase: .closing)
        #expect(lifecycle.visibility == .hidden)
        #expect(lifecycle.closePhase == .closing)
    }

    @Test func closedLeafIsNeverVisible() {
        // The one cross-axis invariant: a closed leaf is gone, so `.closed`
        // normalizes visibility to `.hidden` regardless of the requested value.
        let direct = PaneLifecycle(availability: .unavailable, visibility: .visible, closePhase: .closed)
        #expect(direct.visibility == .hidden)
        let viaLeaf = leaf().lifecycle(isMounted: true, closePhase: .closed)
        #expect(viaLeaf.visibility == .hidden)
        // .closing may still be visible (animating out).
        let closing = PaneLifecycle(availability: .attached, visibility: .visible, closePhase: .closing)
        #expect(closing.visibility == .visible)
    }

    @Test func everyAxisStateIsDeclared() {
        #expect(Set(PaneVisibility.allCases) == [.visible, .hidden])
        #expect(Set(PaneClosePhase.allCases) == [.active, .closing, .closed])
    }
}
