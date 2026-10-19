import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar search interaction", .serialized)
@MainActor
struct SidebarSearchInteractionTests {
    @Test(arguments: ["same", "title", "kind", "execution", "selection", "display", "pinned", "motion", "closed split", "open split"])
    func activityInvalidation(scenario: String) throws {
        let first = TerminalPane(title: "Before", workingDirectory: "/tmp/first", agentKind: .claudeCode, executionPlan: .local)
        let second = TerminalPane(title: "Second", workingDirectory: "/tmp/second", agentKind: .codex, executionPlan: .local)
        let split = scenario.hasSuffix("split")
        let session =
            split
            ? TerminalSession(
                title: "Workspace", workingDirectory: "/tmp",
                layout: .split(TerminalSplit(orientation: .vertical, first: .pane(first), second: .pane(second))), activePaneID: second.id)
            : TerminalSession(title: "Agent", workingDirectory: "/tmp/agent")
        var groups = [SessionGroup(name: "Project", sessions: [session])]
        if scenario == "execution" {
            var pane = try #require(groups[0].sessions[0].activePane)
            pane.agentKind = .claudeCode
            groups[0].sessions[0].layout = .pane(pane)
        }
        let original = groups
        switch scenario {
        case "title": groups[0].sessions[0].title = "Renamed agent"
        case "kind", "execution":
            var pane = try #require(groups[0].sessions[0].activePane)
            if scenario == "kind" { pane.agentKind = .claudeCode } else { pane.agentExecutionState = .running }
            groups[0].sessions[0].layout = .pane(pane)
        case "closed split", "open split":
            var changed = first
            changed.title = "After"
            groups[0].sessions[0].layout = .split(TerminalSplit(orientation: .vertical, first: .pane(changed), second: .pane(second)))
        default: break
        }
        let generation: Int? = scenario == "open split" ? 1 : nil
        let titles: [TerminalSession.ID: String]? = scenario == "open split" ? [session.id: "Workspace"] : nil
        let before = SidebarActivityInvalidationKey(
            groups: original, pinnedSessionIDs: [], selectedSessionID: session.id,
            displayMode: .expanded, reduceMotion: false, activityPanelGeneration: generation, activityPanelDisplayedTitles: titles)
        let after = SidebarActivityInvalidationKey(
            groups: groups, pinnedSessionIDs: scenario == "pinned" ? [session.id] : [],
            selectedSessionID: scenario == "selection" ? nil : session.id,
            displayMode: scenario == "display" ? .collapsed : .expanded, reduceMotion: scenario == "motion",
            activityPanelGeneration: generation, activityPanelDisplayedTitles: titles)
        #expect((before == after) == ["same", "title", "closed split"].contains(scenario))
    }

    @Test(arguments: ["transition", "wrapped", "modified", "AppKit", "nested"])
    func searchNavigation(scenario: String) async throws {
        let nested = scenario == "nested"
        let fixture = try SidebarSearchHostedFixture(
            sessionCount: nested ? 24 : 3,
            viewportHeight: nested ? 230 : 320, mountedSurfaceIndices: nested ? [15] : [0, 1],
            focusSearchThroughAppKit: scenario == "AppKit")
        defer { fixture.close() }
        let initialOffset = fixture.scrollView.contentView.bounds.origin.y
        let expected = nested ? 15 : scenario == "wrapped" || scenario == "modified" ? 0 : 1
        let target = try #require(fixture.surface(for: fixture.sessions[expected]))
        if scenario == "transition" {
            #expect(target.window === fixture.window)
            #expect(fixture.runtime.cachedSurfaceView(for: fixture.sessions[expected].activePaneID) === target)
        }
        if scenario == "modified" {
            fixture.sendArrow(.up, modifiers: .option)
            #expect(fixture.window.firstResponder is NSTextView)
        } else {
            for press in 0..<(nested ? 16 : scenario == "wrapped" ? 4 : 2) {
                fixture.sendArrow(.down, isRepeat: scenario == "AppKit" ? false : press > 0)
            }
        }
        if nested {
            #expect(
                SidebarHostedTestHarness.pumpMainRunLoop(until: { fixture.scrollView.contentView.bounds.origin.y > initialOffset + 20 }))
        }
        fixture.window.resetResponderAttempts()
        await fixture.sendReturn()
        #expect(fixture.store.selectedSessionID == fixture.sessions[expected].id)
        if scenario == "transition" {
            #expect(
                SidebarHostedTestHarness.pumpMainRunLoop(until: { fixture.window.responderAttempts.contains { $0.responder === target } }))
            #expect(fixture.window.responderAttempts.contains { $0.responder === target && $0.succeeded })
            #expect(SidebarHostedTestHarness.pumpMainRunLoop(until: { fixture.window.firstResponder === target }))
        }
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
    let searchField: NSTextField
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
            onSetWorkspaceEmoji: { _ in },
            onRemoveWorkspaceEmoji: { _ in },
            onRenameWorkspaceGroup: { _ in },
            onNewWorkspaceGroup: {},
            onConnectViaSSH: { _ in },
            canMakeWorkspaceManaged: { _ in false },
            onMakeWorkspaceManaged: { _ in },
            onOpenQuickSettings: {},
            onShowWelcomeTour: {},
            onToggleCommandPalette: {},
            onFocusPane: { _, _ in },
            focusRequestID: nil,
            sidebarLiveWidth: SidebarLiveWidth(value: 320),
            resampleSidebarPointer: { nil },
            onSidebarHover: { _ in }
        )
        .environment(settings)
        .environment(UpdateController())
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

        let resolvedSearchField = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSTextField.self,
                in: sidebar.view,
                where: { $0.placeholderString == "Search sessions" }
            )
        )
        searchField = resolvedSearchField
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
                until: { resolvedSearchField.stringValue == "Result" }
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
