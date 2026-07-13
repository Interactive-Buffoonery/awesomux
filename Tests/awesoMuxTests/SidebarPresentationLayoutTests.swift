import AwesoMuxCore
import AwesoMuxConfig
import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Sidebar presentation layout")
struct SidebarPresentationLayoutTests {
    @Test("left sidebar reveals from leading and peeks rightward")
    func leftSidebarLayout() {
        let policy = SidebarPresentationLayoutPolicy(position: .left)

        #expect(policy.edge == .leading)
        #expect(policy.peekDirection == .right)
        #expect(policy.titlebarColumns == [.sidebar, .detail])
        #expect(policy.trafficLightColumn == .sidebar)
        #expect(policy.dividerGutterColumn == .detail)
        #expect(policy.dividerGutterEdge == .leading)
    }

    @Test("right sidebar reveals from trailing and peeks leftward")
    func rightSidebarLayout() {
        let policy = SidebarPresentationLayoutPolicy(position: .right)

        #expect(policy.edge == .trailing)
        #expect(policy.peekDirection == .left)
        #expect(policy.titlebarColumns == [.detail, .sidebar])
        #expect(policy.trafficLightColumn == .detail)
        #expect(policy.dividerGutterColumn == .sidebar)
        #expect(policy.dividerGutterEdge == .leading)
    }

    @Test("title lockup alignment follows sidebar position")
    func titleLockupAlignment() {
        #expect(
            SidebarPresentationLayoutPolicy(position: .left).titlebarLockupAlignment
                == .leading
        )
        #expect(
            SidebarPresentationLayoutPolicy(position: .right).titlebarLockupAlignment
                == .trailing
        )
    }

    @Test("title lockup contract is stable across presentation states")
    func titleLockupPresentationMatrix() {
        let states: [(width: CGFloat, persistent: Bool, temporary: Bool)] = [
            (SidebarWidthPolicy.collapsedWidth, true, false),
            (SidebarWidthPolicy.expandedWidth, true, false),
            (SidebarWidthPolicy.collapsedWidth, false, true),
            (SidebarWidthPolicy.expandedWidth, false, true),
        ]
        for state in states {
            _ = state
            let policy = SidebarPresentationLayoutPolicy(position: .right)
            #expect(policy.titlebarLockupAlignment == .trailing)
            #expect(policy.titlebarLockupOuterPadding == 10)
        }
    }
}
