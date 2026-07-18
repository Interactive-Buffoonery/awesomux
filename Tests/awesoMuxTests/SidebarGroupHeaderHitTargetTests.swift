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

        Self.sendClick(to: window, at: Self.expandedTrailingWhitespacePoint)
        #expect(Self.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        Self.settleMainRunLoop()

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

        Self.sendClick(to: window, at: Self.collapsedRailGutterPoint)
        #expect(Self.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        Self.settleMainRunLoop()

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

        Self.sendClick(to: window, at: Self.collapsedEmptyGroupActionPoint)
        Self.settleMainRunLoop()

        #expect(newWorkspaceCounter.count == 0)
    }

    @Test("badge slot click without hover toggles collapse, never closes the group")
    func badgeSlotClickWithoutHoverTogglesNotCloses() {
        let toggleCounter = ToggleCounter()
        let closeCounter = ToggleCounter()
        let window = Self.makeWindow(
            onToggle: toggleCounter.increment,
            onCloseGroup: closeCounter.increment
        )
        defer { window.close() }

        Self.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(Self.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        Self.settleMainRunLoop()

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

        Self.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(Self.pumpMainRunLoop(until: { closeCounter.count >= 1 }))
        Self.settleMainRunLoop()

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

        Self.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(Self.pumpMainRunLoop(until: { toggleCounter.count >= 1 }))
        Self.settleMainRunLoop()

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
        let hostingView = HitTargetHostingView(
            rootView: SidebarGroupHitTargetHarness(
                isCollapsed: isCollapsed,
                displayMode: displayMode,
                width: width,
                isGroupEmpty: isGroupEmpty,
                totalGroupCount: totalGroupCount,
                headerHoverOverride: headerHoverOverride,
                onToggle: onToggle,
                onCloseGroup: onCloseGroup,
                onNewSessionInGroup: onNewSessionInGroup
            ))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 80)

        let window = HitTargetTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        // SwiftUI gestures are not delivered to the hosted view while the
        // AppKit test window is hidden. Keep it ordered but fully transparent
        // so the harness never flashes over the user's desktop during tests.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        settleMainRunLoop()
        return window
    }

    private static func sendClick(to window: NSWindow, at location: CGPoint) {
        for (type, eventNumber) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: eventNumber,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            else { continue }
            window.sendEvent(event)
        }
    }

    private static func pumpMainRunLoop(
        until condition: () -> Bool = { true },
        timeout: TimeInterval = 1.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            runMainRunLoopSlice()
        }
        return condition()
    }

    private static func settleMainRunLoop(duration: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            runMainRunLoopSlice(maxDuration: deadline.timeIntervalSinceNow)
        }
    }

    private static func runMainRunLoopSlice(maxDuration: TimeInterval = 0.01) {
        RunLoop.main.run(until: Date().addingTimeInterval(min(0.01, max(0, maxDuration))))
    }
}

private final class HitTargetTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class HitTargetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ToggleCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private struct SidebarGroupHitTargetHarness: View {
    let isCollapsed: Bool
    let displayMode: SidebarWidthMode
    let width: CGFloat
    let isGroupEmpty: Bool
    let totalGroupCount: Int
    let headerHoverOverride: Bool?
    let onToggle: () -> Void
    let onCloseGroup: () -> Void
    let onNewSessionInGroup: () -> Void

    @State private var isKeyboardNavigating = false
    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?

    // A non-empty group: the close X gate (SidebarGroupClosePolicy) suppresses
    // only the sole EMPTY group, so an empty single-group harness would gate the
    // X off regardless of hover — the badge-slot test would pass even with the
    // hover gate deleted. With one session, hover is the only remaining
    // suppressor, so the test genuinely guards it. `entries` stays empty (the
    // count badge renders 0 and no tile rows mount, keeping the y=68 header
    // geometry stable); the gate reads the model's `group.sessions`, not entries.
    private var group: SessionGroup {
        SessionGroup(
            id: UUID(uuidString: "8B10C4F3-3905-4C67-A6F6-C7EB11F03D5B")!,
            name: "Workspace group",
            sessions: isGroupEmpty ? [] : [TerminalSession(title: "Workspace", workingDirectory: "~")]
        )
    }

    private var allGroups: [SessionGroup] {
        guard totalGroupCount > 1 else { return [group] }
        return [
            group,
            SessionGroup(
                id: UUID(uuidString: "5068B8D9-5953-4A2F-A50D-D92BF400EA4A")!,
                name: "Other group",
                sessions: []
            ),
        ]
    }

    var body: some View {
        SidebarGroupView(
            group: group,
            entries: [],
            density: SidebarDensity(compact: false),
            tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
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
