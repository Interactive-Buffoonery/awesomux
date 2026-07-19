import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct SidebarGroupHeaderHitTargetTests {
    @Test("test harness window is transparent while ordered for event delivery")
    func testHarnessWindowIsTransparentWhileOrdered() {
        let window = Self.makeWindow(onToggle: {})
        defer { window.close() }

        #expect(window.isVisible)
        #expect(window.alphaValue == 0)
    }

    @Test("group header toggles from trailing whitespace")
    func groupHeaderTogglesFromTrailingWhitespace() {
        let toggleCounter = ToggleCounter()
        let window = Self.makeWindow(onToggle: toggleCounter.increment)
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.expandedTrailingWhitespacePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(toggleCounter.count == 1)
    }

    @Test("collapsed rail group header toggles from rail gutter")
    func collapsedRailGroupHeaderTogglesFromRailGutter() {
        let toggleCounter = ToggleCounter()
        let window = Self.makeWindow(
            isCollapsed: true,
            displayMode: .collapsed,
            width: SidebarWidthPolicy.collapsedWidth,
            onToggle: toggleCounter.increment
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.collapsedRailGutterPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(toggleCounter.count == 1)
    }

    @Test("collapsed rail hides expanded empty-group action")
    func collapsedRailHidesExpandedEmptyGroupAction() {
        let newWorkspaceCounter = ToggleCounter()
        let window = Self.makeWindow(
            displayMode: .collapsed,
            width: SidebarWidthPolicy.collapsedWidth,
            onToggle: {},
            onNewSessionInGroup: newWorkspaceCounter.increment
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.collapsedEmptyGroupActionPoint)
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(newWorkspaceCounter.count == 0)
    }

    @Test("badge slot click without hover toggles collapse, never closes the group")
    func badgeSlotClickWithoutHoverTogglesNotCloses() {
        let toggleCounter = ToggleCounter()
        let closeCounter = ToggleCounter()
        let window = Self.makeWindow(
            headerHoverOverride: false,
            onToggle: toggleCounter.increment,
            onCloseGroup: closeCounter.increment
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(toggleCounter.count == 1)
        #expect(closeCounter.count == 0)
    }

    @Test("hovered empty group among others renders a hittable close X")
    func hoveredEmptyGroupAmongOthersRendersHittableCloseButton() {
        let toggleCounter = ToggleCounter()
        let closeCounter = ToggleCounter()
        let window = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: true,
            onToggle: toggleCounter.increment,
            onCloseGroup: closeCounter.increment
        )
        defer { window.close() }

        let closeRendering = Self.renderedPixels(in: window)
        let badgeWindow = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: false,
            onToggle: {}
        )
        defer { badgeWindow.close() }
        let badgeRendering = Self.renderedPixels(in: badgeWindow)

        #expect(!closeRendering.isEmpty)
        #expect(closeRendering != badgeRendering)

        badgeWindow.close()
        window.makeKeyAndOrderFront(nil)
        SidebarHostedTestHarness.settleMainRunLoop()
        SidebarHostedTestHarness.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { closeCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(closeCounter.count == 1)
        #expect(toggleCounter.count == 0)
    }

    @Test("hovered sole empty group keeps the badge and close action gated")
    func hoveredSoleEmptyGroupKeepsCloseButtonGated() {
        let toggleCounter = ToggleCounter()
        let closeCounter = ToggleCounter()
        let window = Self.makeWindow(
            isGroupEmpty: true,
            headerHoverOverride: true,
            onToggle: toggleCounter.increment,
            onCloseGroup: closeCounter.increment
        )
        defer { window.close() }

        let hoveredRendering = Self.renderedPixels(in: window)
        let badgeWindow = Self.makeWindow(
            isGroupEmpty: true,
            headerHoverOverride: false,
            onToggle: {}
        )
        defer { badgeWindow.close() }
        let badgeRendering = Self.renderedPixels(in: badgeWindow)

        #expect(!hoveredRendering.isEmpty)
        #expect(hoveredRendering == badgeRendering)

        badgeWindow.close()
        window.makeKeyAndOrderFront(nil)
        SidebarHostedTestHarness.settleMainRunLoop()
        SidebarHostedTestHarness.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(toggleCounter.count == 1)
        #expect(closeCounter.count == 0)
    }

    // AppKit window coordinates are bottom-up: y=68 in this 80pt window is
    // 12pt from the top, where the group header is laid out.
    // x=220 is in the trailing Spacer for the production 296pt header,
    // clear of the group name and the trailing count.
    private static let expandedTrailingWhitespacePoint = CGPoint(x: 220, y: 68)

    // The collapsed sidebar is a 60pt rail; x=54 is in the trailing gutter,
    // outside the centered 40pt glyph stack but inside the header content shape.
    private static let collapsedRailGutterPoint = CGPoint(x: 54, y: 68)

    // Empty groups leave their expanded action out of the rail. The sidebar's
    // separate zero-group affordance handles the truly empty app state.
    private static let collapsedEmptyGroupActionPoint = CGPoint(x: 30, y: 30)

    // x=288 sits on the trailing count badge / close-X slot of the 296pt
    // header (content inset 4pt); y=68 is the header row (bottom-up coords).
    private static let expandedCountBadgePoint = CGPoint(x: 288, y: 68)

    private static func makeWindow(
        isCollapsed: Bool = false,
        displayMode: SidebarWidthMode = .expanded,
        width: CGFloat = SidebarWidthPolicy.expandedWidth,
        isGroupEmpty: Bool = false,
        totalGroupCount: Int = 1,
        headerHoverOverride: Bool? = nil,
        onToggle: @escaping () -> Void,
        onCloseGroup: @escaping () -> Void = {},
        onNewSessionInGroup: @escaping () -> Void = {}
    ) -> NSWindow {
        let session = TerminalSession(
            id: UUID(uuidString: "82F876DB-D5C8-4129-AE07-9F0571316E42")!,
            title: "Workspace",
            workingDirectory: "~"
        )
        let group = SessionGroup(
            id: UUID(uuidString: "8B10C4F3-3905-4C67-A6F6-C7EB11F03D5B")!,
            name: "Workspace group",
            sessions: isGroupEmpty ? [] : [session]
        )
        let allGroups =
            totalGroupCount > 1
            ? [
                group,
                SessionGroup(
                    id: UUID(uuidString: "5068B8D9-5953-4A2F-A50D-D92BF400EA4A")!,
                    name: "Other group",
                    sessions: []
                ),
            ]
            : [group]
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: SidebarGroupHitTargetHarness(
                group: group,
                allGroups: allGroups,
                tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
                isCollapsed: isCollapsed,
                displayMode: displayMode,
                width: width,
                totalGroupCount: totalGroupCount,
                headerHoverOverride: headerHoverOverride,
                onToggle: onToggle,
                onCloseGroup: onCloseGroup,
                onNewSessionInGroup: onNewSessionInGroup
            ),
            frame: NSRect(x: 0, y: 0, width: width, height: 80)
        )
        return hosted.window
    }

    private static func renderedPixels(in window: NSWindow) -> Data {
        guard let view = window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
            let bytes = bitmap.bitmapData
        else { return Data() }

        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

}

private final class ToggleCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private struct SidebarGroupHitTargetHarness: View {
    let group: SessionGroup
    let allGroups: [SessionGroup]
    let tint: ProjectTint
    let isCollapsed: Bool
    let displayMode: SidebarWidthMode
    let width: CGFloat
    let totalGroupCount: Int
    let headerHoverOverride: Bool?
    let onToggle: () -> Void
    let onCloseGroup: () -> Void
    let onNewSessionInGroup: () -> Void

    @State private var isKeyboardNavigating = false
    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?

    var body: some View {
        SidebarGroupView(
            group: group,
            entries: [],
            density: SidebarDensity(compact: false),
            tint: tint,
            workspacesWithBackgroundedFloatingWork: [],
            promotedSessionID: nil,
            promotionPulseSessionID: nil,
            isCollapsed: isCollapsed,
            isFiltering: false,
            displayMode: displayMode,
            duplicateDisambiguationBySessionID: [:],
            allGroups: allGroups,
            jumpIndexBySessionID: [:],
            selectedSessionID: nil,
            onToggle: onToggle,
            onSelect: { _ in },
            onNewSessionInGroup: onNewSessionInGroup,
            onConnectViaSSH: { _ in },
            canMakeWorkspaceManaged: { _ in false },
            onMakeWorkspaceManaged: { _ in },
            onNewSessionHere: { _ in },
            onNewGroup: {},
            onRenameGroup: {},
            onSetGroupColor: { _ in },
            canRemoveGroup: false,
            onRemoveGroup: {},
            onCloseGroup: onCloseGroup,
            onAcknowledge: { _ in },
            onMoveSession: { _, _, _ in },
            onMoveGroup: { _, _ in },
            activeDragKind: nil,
            activeDragID: nil,
            activeWorkspaceDragSourceID: nil,
            activeWorkspaceDragSourceGroupID: nil,
            activeDragSourceIsPinned: false,
            onGroupDragStarted: { _ in UUID() },
            onWorkspaceDragStarted: { _ in UUID() },
            onDragRefreshed: { _ in },
            onDragEnded: {},
            onDragExited: {},
            currentGroupIndex: 0,
            totalGroupCount: totalGroupCount,
            onUncollapse: {},
            onClose: { _ in },
            onClear: { _ in },
            onRename: { _ in },
            onToggleNotificationsMute: { _ in },
            onTogglePin: { _ in },
            focusedRowTarget: $focusedRowTarget,
            focusedSearchSessionID: nil,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        .frame(width: width, height: 80, alignment: .topLeading)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.sidebarGroupHeaderHoverOverride, headerHoverOverride)
        // The collapsed header now reads `SidebarPeekModel` for its group
        // roster peek trigger (Task 5) — an ancestor must supply it, same as
        // `ContentView` does in production, or the read is fatal.
        .environment(SidebarPeekModel())
        // The peek direction follows the persisted sidebar side. Production
        // injects this store at the content root; the hosting test must mirror
        // that environment boundary before SwiftUI evaluates the row.
        .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
    }
}
