import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

// The zero-group collapsed rail action (SidebarView.swift's
// `CollapsedEmptySidebarAction`) previously shipped with only a source-text
// assertion covering its keyboard-focus wiring (SidebarHoverIntegrationTests
// .emptySidebarFocusDestination). Nothing actually rendered the rail and
// clicked it to confirm the zero-group visibility gate or the
// create-workspace behavior — this fills that gap using the same
// hosted-click idiom as SidebarGroupHeaderHitTargetTests.
@Suite("Sidebar collapsed empty rail action", .serialized)
@MainActor
struct SidebarCollapsedEmptyRailActionTests {
    @Test("click creates a workspace in the configured default group")
    func clickCreatesDefaultGroupWorkspace() {
        let fixture = SidebarEmptyRailFixture(groups: [])
        defer { fixture.close() }

        fixture.clickActionPoint()

        #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { fixture.store.groups.count == 1 }))
        #expect(fixture.store.groups.first?.name == "awesoMux")
        #expect(fixture.store.selectedSession != nil)
    }

    @Test("does nothing when the rail already has groups")
    func noOpWhenGroupsExist() {
        let fixture = SidebarEmptyRailFixture(
            groups: [
                SessionGroup(
                    name: "Project",
                    sessions: [
                        TerminalSession(title: "Agent", workingDirectory: "/tmp/agent")
                    ])
            ]
        )
        defer { fixture.close() }

        fixture.clickActionPoint()

        // With a group present, CollapsedEmptySidebarAction doesn't render at
        // all — this coordinate instead lands on real group-row content
        // (header or tile, depending on exact row heights), which selects
        // the session (expected — that's real content, not a phantom
        // empty-rail button). The invariant this test actually cares about
        // is narrower: no new workspace got created.
        #expect(fixture.store.groups.count == 1)
        #expect(fixture.store.groups.first?.name == "Project")
        #expect(fixture.store.groups.first?.sessions.count == 1)
    }
}

@MainActor
private final class SidebarEmptyRailFixture {
    let store: SessionStore
    private let window: NSWindow

    // Hosted at the real collapsed-rail width (SidebarWidthPolicy
    // .collapsedWidth) rather than a wider stand-in — the button has zero
    // horizontal slack in production, and this keeps the test honest about
    // that. Collapsed rail layout (`collapsedSearchHeader` +
    // `CollapsedEmptySidebarAction`): 10pt top padding, a 40pt search button,
    // 6pt spacing, a 40pt new-workspace button, 8pt bottom padding — 104pt
    // total — then the action button sits as the first LazyVStack row,
    // centered in the host width. NSHostingView is flipped (top-down), while
    // `sendClick` takes bottom-up window coordinates, hence the height flip.
    private static let hostWidth: CGFloat = SidebarWidthPolicy.collapsedWidth
    private static let windowHeight: CGFloat = 260
    private static let headerHeight: CGFloat = 104
    private static let actionPoint = CGPoint(
        x: hostWidth / 2,
        y: windowHeight - (headerHeight + 20)
    )

    init(groups: [SessionGroup]) {
        store = SessionStore(groups: groups, selectedSessionID: nil, pinnedSessionIDs: [])
        let runtime = GhosttyRuntime()
        let settings = AppSettingsStore(legacySnapshotProvider: { nil })
        let liveWidth = SidebarLiveWidth(value: SidebarWidthPolicy.collapsedWidth)

        let sidebarRoot = SidebarView(
            sessionStore: store,
            ghosttyRuntime: runtime,
            workspacesWithBackgroundedFloatingWork: [],
            promotedSessionID: nil,
            promotionPulseSessionID: nil,
            onCloseWorkspace: { _ in },
            onClearWorkspace: { _ in },
            onCloseWorkspaceGroup: { _ in },
            onRenameWorkspace: { _ in },
            onRenameWorkspaceGroup: { _ in },
            onNewWorkspaceGroup: {},
            onConnectViaSSH: { _ in },
            canMakeWorkspaceManaged: { _ in false },
            onMakeWorkspaceManaged: { _ in },
            onOpenQuickSettings: {},
            onToggleCommandPalette: {},
            onFocusPane: { _, _ in },
            focusRequestID: nil,
            sidebarLiveWidth: liveWidth,
            resampleSidebarPointer: { nil },
            onSidebarHover: { _ in }
        )
        .environment(settings)
        .environment(SidebarPeekModel())
        .appearanceBridge(settings)

        let (window, _) = SidebarHostedTestHarness.makeWindow(
            rootView: AnyView(sidebarRoot),
            frame: NSRect(x: 0, y: 0, width: Self.hostWidth, height: Self.windowHeight)
        )
        self.window = window
    }

    func clickActionPoint() {
        SidebarHostedTestHarness.sendClick(to: window, at: Self.actionPoint)
        SidebarHostedTestHarness.settleMainRunLoop()
    }

    func close() {
        window.close()
    }
}
