import Testing
import AwesoMuxCore
@testable import awesoMux

@Suite("Sidebar hover integration")
struct SidebarHoverIntegrationTests {
    @Test("hidden width toggle changes selection without visibility")
    func hiddenWidthToggle() {
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: 300,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == SidebarWidthPolicy.collapsedWidth)
        #expect(!result.shouldReveal)
    }

    @Test("hidden collapsed width toggle restores remembered full width")
    func hiddenCollapsedWidthToggle() {
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: SidebarWidthPolicy.collapsedWidth,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == 300)
        #expect(!result.shouldReveal)
    }

    @Test("temporarily revealed width toggle uses the live rendered width")
    func temporaryRevealUsesLiveWidth() {
        let currentWidth = SidebarHiddenWidthTogglePolicy.currentWidth(
            committedWidth: 300,
            liveWidth: SidebarWidthPolicy.collapsedWidth,
            isTemporarilyRevealed: true
        )
        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: currentWidth,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: true
        )
        #expect(result.targetWidth == 300)
        #expect(!result.shouldReveal)
    }

    @Test("only pointer transitions animate")
    func transitionKinds() {
        #expect(
            SidebarHoverTransitionPolicy.transition(for: .pointer, reduceMotion: false)
                == .hover(duration: 0.140)
        )
        #expect(
            SidebarHoverTransitionPolicy.transition(for: .pointer, reduceMotion: true) == .immediate
        )
        #expect(
            SidebarHoverTransitionPolicy.transition(for: .explicit, reduceMotion: false) == .immediate
        )
    }

    @Test("availability and explicit invalidation transitions are immediate")
    func invalidationTransitionsAreImmediate() {
        for source in [SidebarVisibilitySource.explicit, .explicit] {
            #expect(
                SidebarHoverTransitionPolicy.transition(for: source, reduceMotion: false)
                    == .immediate
            )
        }
    }

    @Test("persistent visibility ignores a stale dormant pointer transition")
    func persistentVisibilityWinsPointerOrdering() {
        #expect(
            SidebarRuntimeVisibilityPolicy.isVisible(
                proximityState: .dormant,
                userWantsHidden: false
            )
        )
        #expect(
            !SidebarRuntimeVisibilityPolicy.isVisible(
                proximityState: .dormant,
                userWantsHidden: true
            )
        )
    }
}
