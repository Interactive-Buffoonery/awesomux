import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct NewWorkspaceSplitButtonHitTargetTests {
    @Test("primary segment click creates a workspace with a single plain click")
    func primarySegmentClickFiresNewWorkspaceOnce() {
        let counters = ActionCounters()
        let window = Self.makeWindow(
            onNewWorkspace: counters.incrementNewWorkspace,
            onNewWorkspaceInGroup: { _ in counters.incrementNewWorkspaceInGroup() },
            onNewWorkspaceGroup: counters.incrementNewWorkspaceGroup
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counters.newWorkspaceCount >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counters.newWorkspaceCount == 1)
        #expect(counters.newWorkspaceInGroupCount == 0)
        #expect(counters.newWorkspaceGroupCount == 0)
    }

    @Test("two rapid clicks on the primary segment create only one workspace")
    func rapidDoubleClickIsDebouncedToOne() {
        let counters = ActionCounters()
        let window = Self.makeWindow(
            onNewWorkspace: counters.incrementNewWorkspace,
            onNewWorkspaceInGroup: { _ in counters.incrementNewWorkspaceInGroup() },
            onNewWorkspaceGroup: counters.incrementNewWorkspaceGroup
        )
        defer { window.close() }

        // Two clicks back-to-back, well under the 400ms guard interval —
        // this is what the old Menu-gated control couldn't do (the first
        // click consumed itself opening the menu); a plain Button can, so
        // guardedNewWorkspace() exists specifically to catch this.
        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counters.newWorkspaceCount >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counters.newWorkspaceCount == 1)
    }

    @Test("two clicks spaced past the guard interval both create a workspace")
    func clicksPastGuardIntervalBothFire() {
        let counters = ActionCounters()
        let window = Self.makeWindow(
            onNewWorkspace: counters.incrementNewWorkspace,
            onNewWorkspaceInGroup: { _ in counters.incrementNewWorkspaceInGroup() },
            onNewWorkspaceGroup: counters.incrementNewWorkspaceGroup
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counters.newWorkspaceCount >= 1 }))
        // Advance past the 400ms guard interval before the second click —
        // proves the guard is a rolling debounce, not a one-shot lockout.
        SidebarHostedTestHarness.settleMainRunLoop(duration: 0.45)
        SidebarHostedTestHarness.sendClick(to: window, at: Self.primarySegmentPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { counters.newWorkspaceCount >= 2 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(counters.newWorkspaceCount == 2)
    }

    // The 30×30 primary segment sits at the leading edge of the control
    // (HStack(spacing: 0), primary first); (15, 15) is its center. The
    // harness frame below is exactly `30 + 0.5 + 24 = 54.5` wide and `30`
    // tall — the component's own known dimensions, no slack in either axis
    // for SwiftUI to center/align the content within.
    private static let primarySegmentPoint = CGPoint(x: 15, y: 15)

    private static func makeWindow(
        onNewWorkspace: @escaping () -> Void,
        onNewWorkspaceInGroup: @escaping (SessionGroup.ID) -> Void,
        onNewWorkspaceGroup: @escaping () -> Void
    ) -> NSWindow {
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: NewWorkspaceSplitButton(
                restFill: Color.clear,
                otherGroups: [(id: UUID(), name: "Other group")],
                onNewWorkspace: onNewWorkspace,
                onNewWorkspaceInGroup: onNewWorkspaceInGroup,
                onNewWorkspaceGroup: onNewWorkspaceGroup
            ),
            frame: NSRect(x: 0, y: 0, width: 54.5, height: 30)
        )
        return hosted.window
    }
}

private final class ActionCounters {
    private(set) var newWorkspaceCount = 0
    private(set) var newWorkspaceInGroupCount = 0
    private(set) var newWorkspaceGroupCount = 0

    func incrementNewWorkspace() { newWorkspaceCount += 1 }
    func incrementNewWorkspaceInGroup() { newWorkspaceInGroupCount += 1 }
    func incrementNewWorkspaceGroup() { newWorkspaceGroupCount += 1 }
}
