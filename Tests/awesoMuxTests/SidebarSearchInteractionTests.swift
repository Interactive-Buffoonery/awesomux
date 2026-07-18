import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar search interaction", .serialized)
@MainActor
struct SidebarSearchInteractionTests {
    @Test("hosted field intercepts arrows and wraps across pinned and grouped results")
    func hostedFieldInterceptsAndWraps() async throws {
        let transition = try SidebarSearchHostedFixture()
        defer { transition.close() }

        transition.sendArrow(.down)
        transition.sendArrow(.down, isRepeat: true)
        let targetSurface = try #require(transition.surface(for: transition.sessions[1]))
        #expect(targetSurface.window === transition.window)
        #expect(
            transition.runtime.cachedSurfaceView(for: transition.sessions[1].activePaneID)
                === targetSurface
        )
        transition.window.resetResponderAttempts()
        await transition.sendReturn()

        #expect(transition.store.selectedSessionID == transition.sessions[1].id)
        #expect(
            SidebarHostedTestHarness.pumpMainRunLoop(
                until: {
                    transition.window.responderAttempts.contains {
                        $0.responder === targetSurface
                    }
                }
            )
        )
        #expect(
            transition.window.responderAttempts.contains {
                $0.responder === targetSurface && $0.succeeded
            }
        )
        let handedOff = SidebarHostedTestHarness.pumpMainRunLoop(
            until: { transition.window.firstResponder === targetSurface }
        )
        #expect(
            handedOff,
            "actual responder: \(String(describing: transition.window.firstResponder.map { type(of: $0) }))"
        )

        let wrapped = try SidebarSearchHostedFixture()
        defer { wrapped.close() }
        for press in 0..<4 {
            wrapped.sendArrow(.down, isRepeat: press > 0)
        }
        await wrapped.sendReturn()

        #expect(wrapped.store.selectedSessionID == wrapped.sessions[0].id)
    }

    @Test("hosted field passes modified arrows through")
    func hostedFieldPassesModifiedArrowsThrough() async throws {
        let fixture = try SidebarSearchHostedFixture()
        defer { fixture.close() }

        fixture.sendArrow(.up, modifiers: .option)
        #expect(fixture.window.firstResponder is NSTextView)
        await fixture.sendReturn()

        #expect(fixture.store.selectedSessionID == fixture.sessions[0].id)
    }

    @Test("AppKit-focused search field handles result navigation without Tab")
    func appKitFocusedFieldHandlesNavigationWithoutTab() async throws {
        let fixture = try SidebarSearchHostedFixture(focusSearchThroughAppKit: true)
        defer { fixture.close() }

        fixture.sendArrow(.down)
        fixture.sendArrow(.down)
        await fixture.sendReturn()

        #expect(fixture.store.selectedSessionID == fixture.sessions[1].id)
    }

    @Test("hosted nested result target moves the real sidebar scroll view")
    func hostedNestedResultMovesScrollView() async throws {
        let fixture = try SidebarSearchHostedFixture(
            sessionCount: 24,
            viewportHeight: 230,
            mountedSurfaceIndices: [15]
        )
        defer { fixture.close() }
        let initialOffset = fixture.scrollView.contentView.bounds.origin.y

        for press in 0..<16 {
            fixture.sendArrow(.down, isRepeat: press > 0)
        }

        #expect(
            SidebarHostedTestHarness.pumpMainRunLoop(
                until: { fixture.scrollView.contentView.bounds.origin.y > initialOffset + 20 }
            )
        )
        await fixture.sendReturn()
        #expect(fixture.store.selectedSessionID == fixture.sessions[15].id)
    }

}

@MainActor
private final class SidebarSearchHostedFixture {
    enum Arrow {
        case up
        case down

        var keyCode: UInt16 {
            switch self {
            case .up: 126
            case .down: 125
            }
        }

        var characters: String {
            switch self {
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            }
        }
    }

    let sessions: [TerminalSession]
    let store: SessionStore
    let runtime: GhosttyRuntime
    let window: SidebarHostedTestWindow
    let surfaces: [TerminalSession.ID: GhosttySurfaceNSView]
    let scrollView: NSScrollView

    init(
        sessionCount: Int = 3,
        viewportHeight: CGFloat = 320,
        mountedSurfaceIndices: Set<Int> = [0, 1],
        focusSearchThroughAppKit: Bool = false
    ) throws {
        sessions = (0..<sessionCount).map { index in
            TerminalSession(
                title: "Result \(index)",
                workingDirectory: "/tmp/result-\(index)"
            )
        }
        store = SessionStore(
            groups: [SessionGroup(name: "Results", sessions: sessions)],
            selectedSessionID: sessions.last?.id,
            pinnedSessionIDs: sessions.first.map { [$0.id] } ?? []
        )
        runtime = GhosttyRuntime()
        let settings = AppSettingsStore(legacySnapshotProvider: { nil })
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
            sidebarLiveWidth: SidebarLiveWidth(value: 320),
            resampleSidebarPointer: { nil },
            onSidebarHover: { _ in }
        )
        .environment(settings)
        .environment(SidebarPeekModel())
        .appearanceBridge(settings)

        let sidebar = NSHostingController(rootView: sidebarRoot)
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            applicationIsActive: { true }
        )
        controller.terminalMinimumWidth = 320
        window = SidebarHostedTestHarness.makePrimarySplitWindow(
            controller: controller,
            frame: NSRect(x: 0, y: 0, width: 920, height: viewportHeight)
        )

        var createdSurfaces: [TerminalSession.ID: GhosttySurfaceNSView] = [:]
        for index in mountedSurfaceIndices.sorted() {
            _ = try #require(sessions.indices.contains(index))
            let session = sessions[index]
            let pane = try #require(session.activePane)
            let surface = runtime.surfaceView(
                sessionStore: store,
                session: session,
                pane: pane,
                enabledAgentRuntimeFileDropSources: [],
                grokIconEnabled: false
            )
            surface.frame = NSRect(x: 20, y: 20 + index, width: 280, height: 180)
            detail.view.addSubview(surface)
            createdSurfaces[session.id] = surface
        }
        surfaces = createdSurfaces
        detail.view.layoutSubtreeIfNeeded()

        let searchField = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSTextField.self,
                in: sidebar.view,
                where: { $0.placeholderString == "Search sessions" }
            )
        )
        if focusSearchThroughAppKit {
            if let surface = createdSurfaces.values.first {
                _ = window.makeFirstResponder(surface)
            }
            _ = window.makeFirstResponder(searchField)
        } else {
            searchField.selectText(nil)
        }
        SidebarHostedTestHarness.settleMainRunLoop()
        _ = try #require(searchField.currentEditor() as? NSTextView)

        for key in Self.queryKeys {
            SidebarHostedTestHarness.sendKey(
                to: window,
                keyCode: key.keyCode,
                characters: key.character
            )
        }
        #expect(
            SidebarHostedTestHarness.pumpMainRunLoop(
                until: { searchField.stringValue == "Result" }
            )
        )
        scrollView = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSScrollView.self,
                in: sidebar.view
            )
        )
    }

    func sendArrow(
        _ arrow: Arrow,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) {
        SidebarHostedTestHarness.sendKey(
            to: window,
            keyCode: arrow.keyCode,
            characters: arrow.characters,
            // Real hardware arrow events always include .function and
            // .numericPad; matching them here keeps the fixture honest about
            // what the delegate sees in the live app.
            modifiers: modifiers.union([.function, .numericPad]),
            isRepeat: isRepeat
        )
    }

    func sendReturn() async {
        SidebarHostedTestHarness.sendKey(
            to: window,
            keyCode: 36,
            characters: "\r"
        )
        await SidebarHostedTestHarness.drainMainQueue()
    }

    func surface(for session: TerminalSession) -> GhosttySurfaceNSView? {
        surfaces[session.id]
    }

    func close() {
        window.close()
        runtime.discardAllSurfaces()
    }

    private static let queryKeys: [(keyCode: UInt16, character: String)] = [
        (15, "R"),
        (14, "e"),
        (1, "s"),
        (32, "u"),
        (37, "l"),
        (17, "t"),
    ]
}
