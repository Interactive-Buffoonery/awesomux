import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct AppTitlebarInlineRenameTests {
    /// Double-clicking the titlebar workspace name must edit in place, not ask
    /// the app to present `WorkspaceEditSheet`. `onRenameWorkspace` is the sheet
    /// request, so it staying at zero is the observable proof the modal path is
    /// gone. (The sidebar context-menu path still uses that closure — this test
    /// only pins the titlebar caller.)
    @Test("titlebar double-click edits inline instead of requesting the sheet")
    func titlebarDoubleClickDoesNotRequestSheet() throws {
        let renameRequests = ToggleCounter()
        let session = TerminalSession(
            id: UUID(uuidString: "F2F1D0C9-4A21-4C0E-9E3B-7B4A2D6E5F10")!,
            title: "Original title",
            workingDirectory: "~"
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Results", sessions: [session])],
            selectedSessionID: session.id,
            pinnedSessionIDs: []
        )
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: AppTitlebarView(
                session: session,
                sessionStore: store,
                onRenameWorkspace: { _ in renameRequests.increment() },
                sidebarPosition: .left,
                hostPresentation: SidebarHostPresentationState()
            )
            .environment(AppSettingsStore(legacySnapshotProvider: { nil })),
            frame: NSRect(x: 0, y: 0, width: 900, height: AwSpacing.titlebar)
        )
        defer { hosted.window.close() }

        let dragRegion = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSView.self,
                in: hosted.hostingView,
                where: { $0.toolTip == WindowDragRenameHandle.tooltip }
            )
        )

        SidebarHostedTestHarness.sendDoubleClick(
            to: dragRegion,
            at: CGPoint(x: dragRegion.bounds.midX, y: dragRegion.bounds.midY),
            in: hosted.window
        )

        #expect(renameRequests.count == 0)
    }

    /// Closing a workspace mid-rename must not strand a live draft that then
    /// commits against the NEXT workspace. `isEditingTitle` lives on
    /// AppTitlebarView while the field lives inside `workspaceCluster`, which
    /// only renders under `if let session` — so the cancel has to be keyed on
    /// the optional at body level to survive a nil transition.
    @Test("a workspace closing mid-rename does not rename the next one")
    func closingWorkspaceMidRenameDoesNotRenameTheNext() throws {
        let workspaceA = TerminalSession(
            id: UUID(uuidString: "AA000000-0000-4000-8000-000000000001")!,
            title: "Workspace A",
            workingDirectory: "~"
        )
        let workspaceB = TerminalSession(
            id: UUID(uuidString: "BB000000-0000-4000-8000-000000000002")!,
            title: "Workspace B",
            workingDirectory: "~"
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Group", sessions: [workspaceA, workspaceB])],
            selectedSessionID: workspaceA.id,
            pinnedSessionIDs: []
        )
        let hosted = SidebarHostedTestHarness.makeWindow(
            rootView: TitlebarRenameHarness(sessionStore: store)
                .environment(AppSettingsStore(legacySnapshotProvider: { nil })),
            frame: NSRect(x: 0, y: 0, width: 900, height: AwSpacing.titlebar)
        )
        defer { hosted.window.close() }

        let dragRegion = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSView.self,
                in: hosted.hostingView,
                where: { $0.toolTip == WindowDragRenameHandle.tooltip }
            )
        )
        SidebarHostedTestHarness.sendDoubleClick(
            to: dragRegion,
            at: CGPoint(x: dragRegion.bounds.midX, y: dragRegion.bounds.midY),
            in: hosted.window
        )
        SidebarHostedTestHarness.settleMainRunLoop()

        // Confirm edit mode actually engaged — otherwise the rest of this test
        // proves nothing, and it would still go green on the buggy code.
        let field = try #require(
            SidebarHostedTestHarness.firstDescendant(of: NSTextField.self, in: hosted.hostingView),
            "double-click did not enter edit mode; the rest of this test would be vacuous"
        )

        // Workspace A closes, then a DIFFERENT workspace is selected.
        store.selectedSessionID = nil
        SidebarHostedTestHarness.settleMainRunLoop()
        store.selectedSessionID = workspaceB.id
        SidebarHostedTestHarness.settleMainRunLoop()

        // Drive an actual commit. Without this the store is never written and
        // the assertion below passes with or without the Step 8 guard.
        // Return via the field's window; if the field is already torn down by
        // the guard, resigning first responder is a no-op, which is the pass.
        hosted.window.makeFirstResponder(nil)
        SidebarHostedTestHarness.settleMainRunLoop()
        SidebarHostedTestHarness.sendKey(
            to: hosted.window,
            keyCode: 36,  // Return
            characters: "\r"
        )
        SidebarHostedTestHarness.settleMainRunLoop()

        // B must keep its own name — neither A's title nor A's draft.
        #expect(store.session(id: workspaceB.id)?.title == "Workspace B")
        // A must be untouched too: the edit was abandoned, not applied.
        #expect(store.session(id: workspaceA.id)?.title == "Workspace A")
        _ = field
    }
}

private struct TitlebarRenameHarness: View {
    let sessionStore: SessionStore

    var body: some View {
        AppTitlebarView(
            session: sessionStore.selectedSession,
            sessionStore: sessionStore,
            onRenameWorkspace: { _ in },
            sidebarPosition: .left,
            hostPresentation: SidebarHostPresentationState()
        )
    }
}

private final class ToggleCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
