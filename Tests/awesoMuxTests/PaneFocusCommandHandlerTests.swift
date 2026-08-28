import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite
@MainActor
struct PaneFocusCommandHandlerTests {
    @Test("numbered focus reclaims an already-active terminal")
    func numberedFocusReclaimsActiveTerminal() {
        let fixture = makeStore(activeIndex: 1)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(at: 2)

        #expect(requests.count == 1)
        #expect(requests.first?.0 == fixture.sessionID)
        #expect(requests.first?.1 == fixture.paneIDs[1])
        #expect(announcements.isEmpty)
    }

    @Test("numbered focus changes the model, responder target, and announcement together")
    func numberedFocusChangesTarget() {
        let fixture = makeStore(activeIndex: 0)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(at: 3)

        #expect(fixture.store.selectedSession?.activePaneID == fixture.paneIDs[2])
        #expect(requests.count == 1)
        #expect(requests.first?.0 == fixture.sessionID)
        #expect(requests.first?.1 == fixture.paneIDs[2])
        #expect(announcements == [3])
    }

    @Test(arguments: [PaneFocusDirection.previous, .next])
    func directionalFocusRequestsPostMutationTarget(direction: PaneFocusDirection) {
        let fixture = makeStore(activeIndex: 1)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(direction)

        let expectedIndex = direction == .previous ? 0 : 2
        #expect(fixture.store.selectedSession?.activePaneID == fixture.paneIDs[expectedIndex])
        #expect(requests.count == 1)
        #expect(requests.first?.0 == fixture.sessionID)
        #expect(requests.first?.1 == fixture.paneIDs[expectedIndex])
        #expect(announcements == [expectedIndex + 1])
    }

    @Test("invalid or unavailable targets fail closed")
    func unavailableTargetsDoNothing() {
        let fixture = makeStore(activeIndex: 0)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(at: 0)
        handler.focusPane(at: 4)
        handler.focusPane(at: .min)
        handler.focusPane(at: .max)
        fixture.store.selectedSessionID = nil
        handler.focusPane(at: 1)
        handler.focusPane(.next)

        #expect(requests.isEmpty)
        #expect(announcements.isEmpty)
    }

    @Test("numbered focus never targets a reconnect-covered terminal")
    func numberedFocusRejectsReconnectCoveredTerminal() {
        let fixture = makeStore(activeIndex: 0, reconnectIndex: 1)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var clears: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            clears: { clears.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(at: 2)

        #expect(fixture.store.selectedSession?.activePaneID == fixture.paneIDs[1])
        #expect(requests.isEmpty)
        #expect(clears.count == 1)
        #expect(clears.first?.0 == fixture.sessionID)
        #expect(clears.first?.1 == fixture.paneIDs[1])
        #expect(announcements == [2])
    }

    @Test("directional focus never targets a reconnect-covered terminal")
    func directionalFocusRejectsReconnectCoveredTerminal() {
        let fixture = makeStore(activeIndex: 0, reconnectIndex: 1)
        var requests: [(TerminalSession.ID, TerminalPane.ID)] = []
        var clears: [(TerminalSession.ID, TerminalPane.ID)] = []
        var announcements: [Int] = []
        let handler = makeHandler(
            store: fixture.store,
            requests: { requests.append($0) },
            clears: { clears.append($0) },
            announcements: { announcements.append($0) }
        )

        handler.focusPane(.next)

        #expect(fixture.store.selectedSession?.activePaneID == fixture.paneIDs[1])
        #expect(requests.isEmpty)
        #expect(clears.count == 1)
        #expect(clears.first?.0 == fixture.sessionID)
        #expect(clears.first?.1 == fixture.paneIDs[1])
        #expect(announcements == [2])
    }

    @Test("deferred terminal focus eligibility follows live selection and reconnect state")
    func deferredFocusEligibilityUsesLiveState() {
        let live = makeStore(activeIndex: 0)
        #expect(
            PaneFocusCommandHandler.canRequestTerminalFocus(
                sessionID: live.sessionID,
                paneID: live.paneIDs[0],
                sessionStore: live.store
            ))
        #expect(
            !PaneFocusCommandHandler.canRequestTerminalFocus(
                sessionID: live.sessionID,
                paneID: live.paneIDs[1],
                sessionStore: live.store
            ))

        live.store.selectedSessionID = nil
        #expect(
            !PaneFocusCommandHandler.canRequestTerminalFocus(
                sessionID: live.sessionID,
                paneID: live.paneIDs[0],
                sessionStore: live.store
            ))

        let covered = makeStore(activeIndex: 0, reconnectIndex: 0)
        #expect(
            !PaneFocusCommandHandler.canRequestTerminalFocus(
                sessionID: covered.sessionID,
                paneID: covered.paneIDs[0],
                sessionStore: covered.store
            ))
        #expect(
            PaneFocusCommandHandler.canClearTerminalFocus(
                sessionID: covered.sessionID,
                paneID: covered.paneIDs[0],
                sessionStore: covered.store
            ))
        _ = covered.store.focusPane(at: 2, in: covered.sessionID)
        #expect(
            !PaneFocusCommandHandler.canClearTerminalFocus(
                sessionID: covered.sessionID,
                paneID: covered.paneIDs[0],
                sessionStore: covered.store
            ))
    }

    @Test("menu and palette use the shared pane focus handler")
    func commandSurfacesUseSharedHandler() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/App/AwesoMuxApp.swift"),
            encoding: .utf8
        )
        let menu = try #require(
            source.split(separator: "Button(\"Previous Pane\")", maxSplits: 1)
                .last?.split(
                    separator: "Button(\n                    String(\n                        localized: \"Resume Agent Session\"",
                    maxSplits: 1
                ).first
        )
        let palette = try #require(
            source.split(separator: "private var paletteActions: PaletteAppActions", maxSplits: 1)
                .last?.split(separator: "private func openSelectedWorkspaceInIDE()", maxSplits: 1).first
        )

        for section in [menu, palette] {
            #expect(section.contains("paneFocusCommandHandler.focusPane(.previous)"))
            #expect(section.contains("paneFocusCommandHandler.focusPane(.next)"))
            #expect(section.contains("paneFocusCommandHandler.focusPane(at: paneIndex)"))
            #expect(!section.contains("sessionStore.focusPane("))
        }
    }

    private func makeHandler(
        store: SessionStore,
        requests: @escaping ((TerminalSession.ID, TerminalPane.ID)) -> Void,
        clears: @escaping ((TerminalSession.ID, TerminalPane.ID)) -> Void = { _ in },
        announcements: @escaping (Int) -> Void
    ) -> PaneFocusCommandHandler {
        PaneFocusCommandHandler(
            sessionStore: store,
            requestTerminalFocus: { requests(($0, $1)) },
            clearTerminalFocus: { clears(($0, $1)) },
            announcePaneFocused: announcements
        )
    }

    private func makeStore(
        activeIndex: Int,
        reconnectIndex: Int? = nil
    ) -> (store: SessionStore, sessionID: TerminalSession.ID, paneIDs: [TerminalPane.ID]) {
        var panes = [
            TerminalPane(title: "first", workingDirectory: "/first", executionPlan: .local),
            TerminalPane(title: "second", workingDirectory: "/second", executionPlan: .local),
            TerminalPane(title: "third", workingDirectory: "/third", executionPlan: .local),
        ]
        if let reconnectIndex {
            let target = RemoteTarget(user: "deploy", host: "prod.example")!
            panes[reconnectIndex].remoteReconnect = .disconnected(.init(target: target))
        }
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .split(
                    TerminalSplit(
                        orientation: .horizontal,
                        first: .pane(panes[0]),
                        second: .pane(panes[1])
                    )),
                second: .pane(panes[2])
            ))
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: panes[activeIndex].workingDirectory,
            agentKind: .shell,
            layout: layout,
            activePaneID: panes[activeIndex].id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [session])
        ])
        store.selectedSessionID = session.id
        return (store, session.id, panes.map(\.id))
    }
}
