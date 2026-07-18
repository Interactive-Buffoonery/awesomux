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

    @Test func mountedActiveLeafIsLiveAttachedVisible() {
        #expect(leaf().lifecycle() == .live(availability: .attached, visibility: .visible))
    }

    @Test func unmountedActiveLeafIsLiveHidden() {
        #expect(leaf().lifecycle(isMounted: false) == .live(availability: .attached, visibility: .hidden))
    }

    @Test func closingAndClosedAreTerminalStages() {
        #expect(leaf().lifecycle(closePhase: .closing) == .closing)
        #expect(leaf().lifecycle(closePhase: .closed) == .closed)
    }

    // The sum type makes contradictions (closed-but-attached, closed-but-visible)
    // unrepresentable by construction — there is no case that pairs `.closed`
    // with an availability or visibility.
    @Test func everyAxisStateIsDeclared() {
        #expect(Set(PaneVisibility.allCases) == [.visible, .hidden])
        #expect(Set(PaneClosePhase.allCases) == [.active, .closing, .closed])
    }
}
