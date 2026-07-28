import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

/// Papercut 2 (#220) extends the tile stack's drop region down through the
/// inter-group gutter using a padding bracket around `.sidebarDrop`, then
/// reclaims the layout space with negative padding. Both halves rest on
/// undocumented SwiftUI hit-testing behavior, so assert them directly: a
/// toolchain change that clips the overflow, or drops the reclaim, would
/// otherwise revert the fix with a green suite.
///
/// **Coverage limit — read before trusting a green run here.** This suite
/// asserts the registered drag-destination view's *bounds*, not a delivered
/// drag session. AppKit resolves destinations by hit-testing views with
/// registered types, so a registrant spanning the gutter is a sound proxy — but
/// `SidebarHostedTestHarness` has no synthetic drag-session support
/// (`sendClick` hardcodes `clickCount: 1`), so nothing here exercises an
/// end-to-end drop. Manual verification is the only check on the delivered
/// behavior.
@Suite(.serialized)
@MainActor
struct SidebarGroupDropRegionTests {
    @Test("workspace drag extends the tile stack's drop registrant through the gutter")
    func dropRegistrantExtendsThroughGutter() {
        let density = SidebarDensity(compact: false)
        let harness = Self.makeHarness(density: density, isCollapsed: false, activeDragID: UUID())
        defer { harness.window.close() }

        let registrantHeights = Self.dropRegistrantHeights(in: harness.window.contentView!)
        let tallestRegistrant = registrantHeights.max() ?? 0
        let tileStackContentHeight = harness.rowFrames.values.map(\.maxY).max() ?? 0
        // `SidebarRowFramePreferenceKey` is keyed by `TerminalSession.ID`, so
        // `NewWorkspaceInGroupRow` (task 3, #220) — mounted unconditionally as
        // the tile stack's last child — has no session identity to report
        // through it. `tileStackContentHeight` above stops at the last real
        // tile, undercounting the live content by the row's own height plus
        // the one `sessionStackSpacing` gap above it. Measure that
        // contribution from the row's own rendering rather than hardcoding
        // it, so a future visual change to the row still keeps this guard
        // honest.
        let newRowContribution = Self.measuredNewWorkspaceRowContribution(density: density)

        #expect(!registrantHeights.isEmpty)
        #expect(
            abs(
                tallestRegistrant
                    - (tileStackContentHeight + newRowContribution + density.groupStackSpacing)
            ) < 0.5
        )

        // `max()` above always resolves to the tile stack's registrant (far
        // taller), so it can't see the header's own bracket. The header
        // registers a SECOND, smaller drop target — pin it directly against
        // the header's bare fitting height (rendered standalone, with no
        // bracket) plus exactly the one padding line that grows it, so
        // deleting that `.padding(.bottom, density.sessionStackSpacing)`
        // (SidebarGroupView.swift:182) is caught even though it never moves
        // the tallest registrant.
        let headerFittingHeight = Self.measuredHeaderFittingHeight(density: density)
        let shortestRegistrant = registrantHeights.min() ?? 0
        #expect(
            abs(shortestRegistrant - (headerFittingHeight + density.sessionStackSpacing)) < 0.5
        )
    }

    /// `.padding(.bottom, -density.groupStackSpacing)` reclaims what the
    /// positive bracket added, so the tile stack's OWN reported size (to its
    /// parent) should be unaffected. Prove that from live geometry rather
    /// than a hardcoded total: the collapsed variant renders the header
    /// alone (its own bracket always nets to zero, collapsed or not — see
    /// SidebarGroupView.swift:165-206), so `expanded - collapsed` isolates
    /// exactly what the tile-stack section contributes to the group's total
    /// height. If the reclaim breaks, that contribution grows by
    /// `groupStackSpacing` beyond the tile stack's own measured row extent.
    @Test("the padding bracket reclaims its layout space so the tile stack ends flush with the group")
    func paddingBracketReclaimsLayoutSpace() {
        let density = SidebarDensity(compact: false)
        // No active drag needed — the padding bracket and its reclaim are
        // unconditional; only the `.sidebarDrop` registration is drag-gated.
        let expanded = Self.makeHarness(density: density, isCollapsed: false, activeDragID: nil)
        defer { expanded.window.close() }
        let collapsed = Self.makeHarness(density: density, isCollapsed: true, activeDragID: nil)
        defer { collapsed.window.close() }

        let tileStackContentHeight = expanded.rowFrames.values.map(\.maxY).max() ?? 0
        let tileStackSectionContribution =
            expanded.hostingView.fittingSize.height
            - collapsed.hostingView.fittingSize.height
            - density.sessionStackSpacing
        // Same undercount as above — see that test's comment.
        let newRowContribution = Self.measuredNewWorkspaceRowContribution(density: density)

        #expect(
            abs(tileStackSectionContribution - (tileStackContentHeight + newRowContribution)) < 0.5
        )

        // The subtraction above cancels the header's bracket by construction
        // (it contributes identically to both operands), so it can't catch
        // the reclaim itself going missing. Pin `collapsed`'s total directly
        // against the header rendered standalone: the doc comment above
        // already assumes they're equal ("nets to zero"); this is that
        // assumption made falsifiable, and it's the only assertion in this
        // file that would notice `.padding(.bottom, -density.sessionStackSpacing)`
        // (SidebarGroupView.swift:206) being deleted.
        let headerFittingHeight = Self.measuredHeaderFittingHeight(density: density)
        #expect(abs(collapsed.hostingView.fittingSize.height - headerFittingHeight) < 0.5)
    }

    /// An empty group's `+ new workspace` row is its SOLE drop target — the
    /// list delegate deliberately stands aside there
    /// (`NewWorkspaceInGroupRowPolicy.ownsDropDelegate`) — and its only
    /// pointer path to creating a workspace. Compact density is the tight
    /// case: every child of the row's `HStack` is short (a 10pt glyph, a 10pt
    /// mono face), so without a floor the row lands under the WCAG 2.5.8 24pt
    /// minimum. Measured from live geometry, so a font or padding change that
    /// eats the margin is caught rather than silently shipped.
    @Test("the empty group's create row clears the 24pt pointer-target minimum in both densities")
    func emptyGroupCreateRowClearsPointerTargetMinimum() {
        for density in [SidebarDensity(compact: true), SidebarDensity(compact: false)] {
            let height = Self.measuredNewWorkspaceRowHeight(density: density, isGroupEmpty: true)
            #expect(height >= 24, "row measured \(height)pt")
        }
    }

    /// Renders `NewWorkspaceInGroupRow` in isolation, exactly as a populated
    /// group configures it (`NewWorkspaceInGroupRowPolicy` with
    /// `isGroupEmpty: false`), and measures its real height plus the one
    /// `sessionStackSpacing` gap the tile stack's `VStack` inserts above it.
    /// Live geometry, not a hardcoded constant — a font or padding change to
    /// the row keeps this guard's expectation in sync automatically.
    private static func measuredNewWorkspaceRowContribution(density: SidebarDensity) -> CGFloat {
        measuredNewWorkspaceRowHeight(density: density, isGroupEmpty: false)
            + density.sessionStackSpacing
    }

    /// The row's own rendered height, with no stack spacing folded in — the
    /// number WCAG 2.5.8 applies to, since the row IS the pointer target.
    private static func measuredNewWorkspaceRowHeight(
        density: SidebarDensity,
        isGroupEmpty: Bool
    ) -> CGFloat {
        let row = NewWorkspaceInGroupRow(
            isFiltering: false,
            groupName: "Group",
            showsRestingBorder: NewWorkspaceInGroupRowPolicy.showsRestingBorder(isGroupEmpty: isGroupEmpty),
            ownsDropDelegate: NewWorkspaceInGroupRowPolicy.ownsDropDelegate(isGroupEmpty: isGroupEmpty),
            activeDragKind: nil,
            activeDragID: nil,
            activeDragSourceIsPinned: false,
            verticalPadding: density.emptyGroupVerticalPadding,
            onNewSessionInGroup: {},
            onDragRefreshed: { _ in },
            onDragEnded: {},
            onDragExited: {},
            onAcceptDrop: { _ in }
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .topLeading)

        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: row,
            frame: NSRect(x: 0, y: 0, width: 260, height: 80)
        )
        defer { hosted.window.close() }
        hosted.hostingView.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()

        return hosted.hostingView.fittingSize.height
    }

    /// Walks the hosted `NSView` tree for views with registered drag types —
    /// the same technique the plan's probe used to falsify the bracket
    /// empirically before this fix was written. A registrant only exists
    /// while `.sidebarDrop` is enabled, which requires a live workspace drag.
    private static func dropRegistrantHeights(in root: NSView) -> [CGFloat] {
        var heights: [CGFloat] = []
        func walk(_ view: NSView) {
            if !view.registeredDraggedTypes.isEmpty {
                heights.append(view.bounds.height)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return heights
    }

    private struct Harness {
        let window: NSWindow
        let hostingView: NSView
        let rowFrames: [TerminalSession.ID: CGRect]
    }

    /// Shared by `makeHarness` and `measuredHeaderFittingHeight` — the header
    /// standalone measurement is only a valid stand-in for the header AS
    /// RENDERED inside `SidebarGroupView` if both see the identical group
    /// (same name/count driving the header's badge and title width).
    private static func makeGroupAndEntries() -> (SessionGroup, [SidebarSessionEntry]) {
        let groupID = UUID(uuidString: "3E9E6E0B-2E9D-4F0B-9A3E-8C2C2E7B9A31")!
        let sessionA = TerminalSession(
            id: UUID(uuidString: "8B7C1D3E-1B0A-4B2E-9C3D-1A2B3C4D5E6F")!,
            title: "Workspace A",
            workingDirectory: "~"
        )
        let sessionB = TerminalSession(
            id: UUID(uuidString: "2F3E4D5C-6B7A-4988-8D9E-0F1A2B3C4D5E")!,
            title: "Workspace B",
            workingDirectory: "~"
        )
        let group = SessionGroup(
            id: groupID,
            name: "Drop region group",
            sessions: [sessionA, sessionB]
        )
        let entries = group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
        return (group, entries)
    }

    /// Renders `SidebarGroupHeaderRow` alone, mirroring how
    /// `measuredNewWorkspaceRowContribution` isolates the new-workspace row —
    /// live geometry for the header's OWN size, with no bracket applied, so
    /// it can be compared against the bracketed sizes measured elsewhere.
    private static func measuredHeaderFittingHeight(density: SidebarDensity) -> CGFloat {
        let (group, entries) = Self.makeGroupAndEntries()
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: HeaderOnlyHarnessView(group: group, entries: entries, density: density),
            frame: NSRect(x: 0, y: 0, width: 260, height: 80)
        )
        defer { hosted.window.close() }
        hosted.hostingView.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()

        return hosted.hostingView.fittingSize.height
    }

    private static func makeHarness(
        density: SidebarDensity,
        isCollapsed: Bool,
        activeDragID: UUID?
    ) -> Harness {
        let (group, entries) = Self.makeGroupAndEntries()
        var capturedRowFrames: [TerminalSession.ID: CGRect] = [:]

        let rootView = DropRegionHarnessView(
            group: group,
            entries: entries,
            density: density,
            isCollapsed: isCollapsed,
            activeDragID: activeDragID,
            onRowFrames: { capturedRowFrames = $0 }
        )

        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: rootView,
            frame: NSRect(x: 0, y: 0, width: 260, height: 400)
        )
        // The harness view sizes itself to fit content; force a layout pass
        // so the preference callback above has run before we read it.
        hosted.hostingView.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()

        return Harness(
            window: hosted.window,
            hostingView: hosted.hostingView,
            rowFrames: capturedRowFrames
        )
    }
}

private struct DropRegionHarnessView: View {
    let group: SessionGroup
    let entries: [SidebarSessionEntry]
    let density: SidebarDensity
    let isCollapsed: Bool
    let activeDragID: UUID?
    let onRowFrames: ([TerminalSession.ID: CGRect]) -> Void

    @State private var isKeyboardNavigating = false
    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?

    var body: some View {
        SidebarGroupView(
            group: group,
            entries: entries,
            density: density,
            tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
            workspacesWithBackgroundedFloatingWork: [],
            promotedSessionID: nil,
            promotionPulseSessionID: nil,
            isCollapsed: isCollapsed,
            isFiltering: false,
            displayMode: .expanded,
            duplicateDisambiguationBySessionID: [:],
            allGroups: [group],
            jumpIndexBySessionID: [:],
            selectedSessionID: nil,
            onToggle: {},
            onSelect: { _ in },
            onNewSessionInGroup: {},
            onConnectViaSSH: { _ in },
            canMakeWorkspaceManaged: { _ in false },
            onMakeWorkspaceManaged: { _ in },
            onNewSessionHere: { _ in },
            onNewGroup: {},
            onRenameGroup: {},
            onSetGroupColor: { _ in },
            onCloseGroup: {},
            onAcknowledge: { _ in },
            onMoveSession: { _, _, _ in },
            onMoveGroup: { _, _ in },
            activeDragKind: activeDragID != nil ? .workspace : nil,
            activeDragID: activeDragID,
            activeWorkspaceDragSourceID: nil,
            activeWorkspaceDragSourceGroupID: nil,
            activeDragSourceIsPinned: false,
            onGroupDragStarted: { _ in UUID() },
            onWorkspaceDragStarted: { _ in UUID() },
            onDragRefreshed: { _ in },
            onDragEnded: {},
            onDragExited: {},
            currentGroupIndex: 0,
            totalGroupCount: 1,
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
        .onPreferenceChange(SidebarRowFramePreferenceKey.self) { onRowFrames($0) }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .topLeading)
        .environment(\.dynamicTypeSize, .large)
        // The collapsed-header peek trigger and appearance settings both
        // read ancestor environment objects in production (ContentView
        // supplies them) — the hosted test must mirror that boundary or
        // the read is fatal.
        .environment(SidebarPeekModel())
        .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
    }
}

/// The header alone, with no bracket — same group/entries and structural
/// params (`currentGroupIndex`, `totalGroupCount`, `displayMode`, etc.) as
/// `DropRegionHarnessView` passes into `SidebarGroupView`, so its fitting
/// height is comparable to the header's height when it's measured through
/// that wrapper.
private struct HeaderOnlyHarnessView: View {
    let group: SessionGroup
    let entries: [SidebarSessionEntry]
    let density: SidebarDensity

    @State private var isKeyboardNavigating = false
    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?

    var body: some View {
        SidebarGroupHeaderRow(
            group: group,
            entries: entries,
            density: density,
            tint: ProjectTint(groupName: group.name, color: group.color, index: 0),
            isCollapsed: false,
            isFiltering: false,
            displayMode: .expanded,
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
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .topLeading)
        .environment(SidebarPeekModel())
        .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
    }
}
