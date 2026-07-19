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

    // The 30×30 primary segment sits at the leading edge of the control
    // (HStack(spacing: 0), primary first); (15, 15) is its center. The
    // harness frame below is exactly `30 + 0.5 + 22 = 52.5` wide and `30`
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
            frame: NSRect(x: 0, y: 0, width: 52.5, height: 30)
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
