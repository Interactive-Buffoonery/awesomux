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

        #expect(!registrantHeights.isEmpty)
        #expect(
            abs(tallestRegistrant - (tileStackContentHeight + density.groupStackSpacing)) < 0.5
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

        #expect(abs(tileStackSectionContribution - tileStackContentHeight) < 0.5)
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

    private static func makeHarness(
        density: SidebarDensity,
        isCollapsed: Bool,
        activeDragID: UUID?
    ) -> Harness {
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
            canRemoveGroup: false,
            onRemoveGroup: {},
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
