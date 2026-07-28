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

    /// The X draws a 9pt glyph; what must clear WCAG 2.5.8's 24pt minimum is
    /// the *target* frame around it. This is the group's only pointer close
    /// path — the `+ new workspace` row's duplicate X (and the 24pt guard that
    /// came with it) is gone — so the base size carries the whole requirement.
    /// `textScaleFactor` only ever scales it up.
    @Test("the header close X's pointer target clears the 24x24 minimum")
    func closeTargetMeetsMinimumSize() {
        #expect(SidebarGroupHeaderRow.closeTargetBaseSize >= 24)
    }

    /// Declaring a 24pt target is not the same as having one. The X is a
    /// trailing OVERLAY on the header, so it is centred on whatever height the
    /// header happens to be — and the header was shorter than the target it
    /// hosts (measured: 20pt comfortable, 16pt compact, against a 24pt X). The
    /// overflow was invisible until the X joined the focus order, at which
    /// point the ring's top stroke was clipped away by the sidebar's
    /// `ScrollView`; the same clip takes the top of the *pointer target* with
    /// it, which is the part that actually matters.
    ///
    /// Asserted per density, because compact is where the gap was worst and a
    /// single-density check would have passed while compact stayed broken.
    @Test(
        "the header row is at least as tall as the pointer target it hosts",
        arguments: [false, true])
    func headerRowFitsItsCloseTarget(isCompact: Bool) {
        let height = Self.headerRowHeight(density: SidebarDensity(compact: isCompact))

        #expect(height > 0, "premise: the header must render at all")

        #expect(
            height >= SidebarGroupHeaderRow.closeTargetBaseSize,
            "header row \(height)pt cannot contain its own \(SidebarGroupHeaderRow.closeTargetBaseSize)pt close target"
        )
    }

    /// The floor above is applied to the whole header flow, including the
    /// collapsed rail — which renders no count badge and therefore no close X,
    /// and which sets its own 26pt height inside `groupHeader`.
    ///
    /// Review question: does a 24pt floor shrink or otherwise disturb that?
    /// It does not, and the reason is that the floor is never the binding
    /// constraint there — the rail's own 26pt plus the shared bottom padding
    /// already exceeds it. Asserting that relationship rather than a literal:
    /// a first pass at this test guessed `== 26` and measured 29pt / 27pt,
    /// because the rail's 26pt is set INSIDE `groupHeader` and the bottom
    /// padding is added outside it.
    ///
    /// Measured rather than argued because "minHeight only raises, so it
    /// obviously can't matter" is the same shape of reasoning about this
    /// overlay that shipped the clipped target in the first place.
    @Test(
        "the close-target floor never binds on the collapsed rail",
        arguments: [false, true])
    func collapsedRailKeepsItsOwnHeight(isCompact: Bool) {
        let density = SidebarDensity(compact: isCompact)
        let railHeight = Self.headerRowHeight(
            density: density,
            displayMode: .collapsed,
            width: SidebarWidthPolicy.collapsedWidth
        )

        #expect(
            railHeight == 26 + density.groupHeaderBottomPadding,
            "the rail should still be its own 26pt plus the shared bottom padding: got \(railHeight)")
        #expect(
            railHeight > SidebarGroupHeaderRow.closeTargetBaseSize,
            "if this ever drops to the floor, the floor has started driving the rail's height")
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

    /// An expanded empty group rests its close X visible: the body below the
    /// header already shows the group is empty, so the count badge says nothing
    /// and the X takes that slot without waiting for hover. Pinned at the pixel
    /// level because it is the reason the `+ new workspace` row no longer
    /// carries its own duplicate X — if this silently reverted to hover-only,
    /// an empty group would have no resting way to close it at all.
    @Test("expanded empty group renders the same close X hovered or not")
    func expandedEmptyGroupRestsCloseButtonVisible() {
        let window = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: true,
            onToggle: {}
        )
        defer { window.close() }
        let closeRendering = Self.renderedPixels(in: window)

        let restingWindow = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: false,
            onToggle: {}
        )
        defer { restingWindow.close() }
        let restingRendering = Self.renderedPixels(in: restingWindow)

        #expect(!closeRendering.isEmpty)
        #expect(
            closeRendering == restingRendering,
            "hover must not change an expanded empty group's header — the X already rests there")
    }

    /// The resting X is clickable WITHOUT hover — the point of the whole
    /// change. Hit-testing follows visibility exactly, because an X that is
    /// drawn but swallows clicks is its own bug.
    ///
    /// The cost is accepted deliberately: closing a group rebuilds the list and
    /// can slide the next resting X under a pointer that never moved, so a
    /// repeated click in one spot can close more than one group. Gating on
    /// hover does NOT prevent that (the arriving header receives a genuine
    /// hover-enter, verified by hand), and `removeGroup` registers undo, so the
    /// cascade is recoverable rather than destructive.
    @Test("the resting X closes the group without ever being hovered")
    func restingCloseButtonIsClickableWithoutHover() {
        let restingToggle = ToggleCounter()
        let restingClose = ToggleCounter()
        let restingWindow = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: false,
            onToggle: restingToggle.increment,
            onCloseGroup: restingClose.increment
        )
        defer { restingWindow.close() }

        SidebarHostedTestHarness.sendClick(to: restingWindow, at: Self.expandedCountBadgePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { restingClose.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        // Closes rather than falling through to the header's collapse toggle —
        // the same outcome a hovered X produces, which is the contract.
        #expect(restingClose.count == 1)
        #expect(restingToggle.count == 0)
    }

    /// Collapsed, the group's rows are hidden, so the count is the only signal
    /// of what is inside and it keeps the slot — the X goes back to being a
    /// hover reveal. This is the half of the rule the expanded case inverts, so
    /// pin it too: collapsing must not silently inherit the resting X.
    @Test("collapsed empty group keeps its count until hover")
    func collapsedEmptyGroupKeepsCountUntilHover() {
        let restingWindow = Self.makeWindow(
            isCollapsed: true,
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: false,
            onToggle: {}
        )
        defer { restingWindow.close() }
        let restingRendering = Self.renderedPixels(in: restingWindow)

        let hoveredWindow = Self.makeWindow(
            isCollapsed: true,
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: true,
            onToggle: {}
        )
        defer { hoveredWindow.close() }
        let hoveredRendering = Self.renderedPixels(in: hoveredWindow)

        #expect(!restingRendering.isEmpty)
        #expect(
            restingRendering != hoveredRendering,
            "a collapsed empty group must still morph count → X on hover")
    }

    /// This used to assert the opposite: the sole empty group kept its count
    /// badge and its click toggled collapse, because the store refused to
    /// remove the last group and a resting X there would have been a dead
    /// control. The store now accepts it, so the carve-out is gone and the
    /// last group behaves like every other empty one — the X rests in the
    /// count slot and the click closes.
    ///
    /// Rendered against a two-group control rather than asserted alone: equal
    /// pixels prove group count no longer changes what the header draws, which
    /// is the actual claim.
    @Test("the sole empty group rests its close X like any other empty group")
    func soleEmptyGroupRestsCloseButton() {
        let toggleCounter = ToggleCounter()
        let closeCounter = ToggleCounter()
        let window = Self.makeWindow(
            isGroupEmpty: true,
            headerHoverOverride: false,
            onToggle: toggleCounter.increment,
            onCloseGroup: closeCounter.increment
        )
        defer { window.close() }

        let soleRendering = Self.renderedPixels(in: window)
        let amongOthersWindow = Self.makeWindow(
            isGroupEmpty: true,
            totalGroupCount: 2,
            headerHoverOverride: false,
            onToggle: {}
        )
        defer { amongOthersWindow.close() }
        let amongOthersRendering = Self.renderedPixels(in: amongOthersWindow)

        #expect(!soleRendering.isEmpty)
        #expect(
            soleRendering == amongOthersRendering,
            "the sole empty group must draw the same resting X as one among others")

        amongOthersWindow.close()
        window.makeKeyAndOrderFront(nil)
        SidebarHostedTestHarness.settleMainRunLoop()
        SidebarHostedTestHarness.sendClick(to: window, at: Self.expandedCountBadgePoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { closeCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(closeCounter.count == 1)
        #expect(toggleCounter.count == 0, "the click must close, not toggle collapse")
    }

    @Test("populated group's new-workspace row creates a workspace")
    func populatedGroupNewWorkspaceRowCreatesWorkspace() {
        let newWorkspaceCounter = ToggleCounter()
        let session = TerminalSession(
            id: UUID(uuidString: "0B1B7A26-0F1A-4F4D-9C41-2C6E9F0F41A2")!,
            title: "Populated workspace",
            workingDirectory: "~"
        )
        let window = Self.makeWindow(
            height: Self.populatedGroupWindowHeight,
            entries: [SidebarSessionEntry(session: session, match: nil)],
            onToggle: {},
            onNewSessionInGroup: newWorkspaceCounter.increment
        )
        defer { window.close() }

        SidebarHostedTestHarness.sendClick(to: window, at: Self.populatedGroupNewWorkspaceRowPoint)
        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { newWorkspaceCounter.count >= 1 }))
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(newWorkspaceCounter.count == 1)
    }

    /// A point 30pt above the calibrated row click lands on the session tile
    /// above it, not the row — proving the calibration isn't accidentally
    /// landing on the wrong control (whose button would also fire a create,
    /// masking a miscalibrated point as a false pass).
    @Test("a point above the populated row's calibrated click misses it")
    func pointAboveCalibratedRowClickMisses() {
        let newWorkspaceCounter = ToggleCounter()
        let session = TerminalSession(
            id: UUID(uuidString: "0B1B7A26-0F1A-4F4D-9C41-2C6E9F0F41A2")!,
            title: "Populated workspace",
            workingDirectory: "~"
        )
        let window = Self.makeWindow(
            height: Self.populatedGroupWindowHeight,
            entries: [SidebarSessionEntry(session: session, match: nil)],
            onToggle: {},
            onNewSessionInGroup: newWorkspaceCounter.increment
        )
        defer { window.close() }

        let aboveRowPoint = CGPoint(
            x: Self.populatedGroupNewWorkspaceRowPoint.x,
            y: Self.populatedGroupNewWorkspaceRowPoint.y + 30
        )
        SidebarHostedTestHarness.sendClick(to: window, at: aboveRowPoint)
        SidebarHostedTestHarness.settleMainRunLoop()

        #expect(newWorkspaceCounter.count == 0)
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

    /// The default 80pt harness window fits a header alone, or a header plus
    /// one short row — not a header, a real ~55pt session tile, AND the new
    /// row. At 80pt the row renders below y=0 (outside the window, unclickable).
    /// 140pt gives every element room with margin to spare.
    private static let populatedGroupWindowHeight: CGFloat = 140

    /// The row sits below the header and the single session tile, centered in
    /// its own measured band (y 31–58 at `populatedGroupWindowHeight`). Y is
    /// measured from the harness window's bottom edge, matching the other
    /// constants here.
    private static let populatedGroupNewWorkspaceRowPoint = CGPoint(x: 100, y: 44)

    private static func makeWindow(
        density: SidebarDensity = SidebarDensity(compact: false),
        isCollapsed: Bool = false,
        displayMode: SidebarWidthMode = .expanded,
        width: CGFloat = SidebarWidthPolicy.expandedWidth,
        // 80pt fits a header alone or a header plus one short row. A real
        // session tile is ~55pt (title + path + status rows), so a populated
        // group with the new-workspace row below it overflows 80pt and
        // renders the row at a negative, unclickable y — callers with real
        // tile content must pass a taller window.
        height: CGFloat = 80,
        isGroupEmpty: Bool = false,
        entries: [SidebarSessionEntry] = [],
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
            // Keep the group and the rendered entries in sync — a tile whose
            // session isn't in its own group is a state the real projection
            // cannot produce.
            sessions: isGroupEmpty ? [] : (entries.isEmpty ? [session] : entries.map(\.session))
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
                entries: entries,
                allGroups: allGroups,
                tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
                density: density,
                isCollapsed: isCollapsed,
                displayMode: displayMode,
                width: width,
                height: height,
                totalGroupCount: totalGroupCount,
                headerHoverOverride: headerHoverOverride,
                onToggle: onToggle,
                onCloseGroup: onCloseGroup,
                onNewSessionInGroup: onNewSessionInGroup
            ),
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        return hosted.window
    }

    /// `.focusable(showsGroupCloseButton)` is what gives keyboard users the
    /// same reach as the pointer — the X was `.focusable(false)` before,
    /// because an INVISIBLE X that Tab could still fire is a trap. A resting
    /// visible one is ordinary UI.
    ///
    /// This used to hang a second baseline off the sole empty group, where the
    /// X was hidden because closing it would have been a dead control. The
    /// store now accepts removing the last group, so that state rests its X
    /// like every other empty group and can no longer serve as a baseline.
    ///
    /// Two replacements were measured and rejected, both for the same reason —
    /// they move a focusable that is not the X, so an equal count would prove
    /// nothing: a *collapsed* empty group and a *filtered* one each hide the
    /// `+ new workspace` row as well (1 focusable, against 2 for the populated
    /// baseline).
    ///
    /// So the control changes exactly one input instead: hover, on the same
    /// populated group. That isolates the X's contribution outright, and the
    /// resting case is then asserted to reach the same total — a resting X
    /// gives the keyboard the same reach a hovered one does, which is the
    /// actual claim.
    ///
    /// Counts are compared to each other, never to a literal: a focusable
    /// SwiftUI `Button` currently publishes two key-view shims, and that ratio
    /// is an implementation detail no test should pin.
    @Test("the resting close X joins the keyboard focus order")
    func restingCloseButtonJoinsFocusOrder() {
        func focusStops(isGroupEmpty: Bool, isHovered: Bool) -> Int {
            let window = Self.makeWindow(
                isGroupEmpty: isGroupEmpty,
                headerHoverOverride: isHovered,
                onToggle: {}
            )
            defer { window.close() }
            return Self.keyViewCount(in: window)
        }

        let populatedHidden = focusStops(isGroupEmpty: false, isHovered: false)
        let populatedShown = focusStops(isGroupEmpty: false, isHovered: true)
        let emptyResting = focusStops(isGroupEmpty: true, isHovered: false)

        #expect(populatedHidden > 0, "premise: the header must publish focusables at all")
        #expect(
            populatedShown > populatedHidden,
            "the X must add focus stops; hover was the only input that changed: \(populatedShown) vs \(populatedHidden)"
        )
        #expect(
            emptyResting == populatedShown,
            "a resting X should reach the keyboard exactly as a hovered one does: \(emptyResting) vs \(populatedShown)"
        )
    }

    /// SwiftUI publishes each focusable item as a key-view-capable `NSView`
    /// shim in the hosted tree, so counting them is a real readback of the
    /// keyboard focus order — unlike this view's accessibility tree, which
    /// hosts empty. Counted by capability, never by private class name.
    private static func keyViewCount(in window: NSWindow) -> Int {
        window.makeKeyAndOrderFront(nil)
        SidebarHostedTestHarness.settleMainRunLoop()
        guard let root = window.contentView else { return 0 }

        var count = 0
        func walk(_ view: NSView) {
            if view.canBecomeKeyView { count += 1 }
            view.subviews.forEach(walk)
        }
        walk(root)
        return count
    }

    /// The header row's rendered height, read back from the hosted tree.
    ///
    /// Measures `SidebarGroupHeaderRow` ON ITS OWN, rather than fishing it out
    /// of a rendered `SidebarGroupView`.
    ///
    /// Two tree-walking versions were written and both passed against the
    /// broken layout, which is why this does not walk the tree at all:
    ///   1. "tallest view under a height ceiling" measured the 24pt close
    ///      button itself — the target compared against itself, so it read 24
    ///      however short the row it overflowed.
    ///   2. Adding a full-width requirement to exclude the button then picked
    ///      up the `+ new workspace` row, which an empty group also renders.
    ///
    /// `sizeThatFits` on the header alone has no such neighbours to confuse.
    /// It also measures exactly the right quantity: an overlay does not
    /// contribute to its parent's size, so this reports the row's own height —
    /// which is precisely what the close button overflows.
    private static func headerRowHeight(
        density: SidebarDensity,
        displayMode: SidebarWidthMode = .expanded,
        width: CGFloat = SidebarWidthPolicy.expandedWidth
    ) -> CGFloat {
        let controller = NSHostingController(
            rootView: HeaderRowMeasurementHarness(
                density: density, displayMode: displayMode, width: width))
        // Force a layout pass; `sizeThatFits` on a never-displayed controller
        // otherwise reports zero.
        controller.view.layoutSubtreeIfNeeded()
        return controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
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

/// Just the header row, with nothing above or below it, so its own height is
/// the only thing there is to measure.
private struct HeaderRowMeasurementHarness: View {
    let density: SidebarDensity
    let displayMode: SidebarWidthMode
    let width: CGFloat

    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?
    @State private var isKeyboardNavigating = false

    var body: some View {
        let group = SessionGroup(
            id: UUID(uuidString: "8B10C4F3-3905-4C67-A6F6-C7EB11F03D5B")!,
            name: "Workspace group",
            sessions: []
        )
        SidebarGroupHeaderRow(
            group: group,
            entries: [],
            density: density,
            tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
            isCollapsed: displayMode == .collapsed,
            isFiltering: false,
            displayMode: displayMode,
            selectedSessionID: nil,
            currentGroupIndex: 0,
            totalGroupCount: 1,
            isDragActive: false,
            onToggle: {},
            onNewSessionInGroup: {},
            onConnectViaSSH: { _ in },
            onNewGroup: {},
            onRenameGroup: {},
            onSetGroupColor: { _ in },
            onCloseGroup: {},
            onMoveGroup: { _, _ in },
            onGroupDragStarted: { _ in UUID() },
            focusedRowTarget: $focusedRowTarget,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        .frame(width: width)
        .environment(\.dynamicTypeSize, .large)
        .environment(SidebarPeekModel())
        .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
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
    let entries: [SidebarSessionEntry]
    let allGroups: [SessionGroup]
    let tint: ProjectTint
    let density: SidebarDensity
    let isCollapsed: Bool
    let displayMode: SidebarWidthMode
    let width: CGFloat
    let height: CGFloat
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
            entries: entries,
            density: density,
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
        .frame(width: width, height: height, alignment: .topLeading)
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
