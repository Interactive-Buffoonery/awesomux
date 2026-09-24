import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("RecentlyClosedWorkspace — capture, persistence, reopen")
struct RecentlyClosedWorkspaceTests {

    // MARK: - Helpers

    private static func makeStore(
        sessionCount: Int = 1,
        groupName: String = "awesoMux"
    ) -> SessionStore {
        var sessions: [TerminalSession] = []
        for index in 0..<sessionCount {
            sessions.append(
                TerminalSession(
                    title: "ws-\(index)",
                    workingDirectory: NSHomeDirectory(),
                    isTitleUserEdited: true,
                    agentKind: .shell,
                    agentState: .idle
                ))
        }
        let group = SessionGroup(name: groupName, sessions: sessions)
        let store = SessionStore(groups: [group])
        store.selectedSessionID = sessions.first?.id
        return store
    }

    // MARK: - TTL

    @Test("entries older than the TTL are pruned at restore time")
    func pruneOnRestore() throws {
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "stale", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "ghost-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let fresh = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "fresh",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "fresh", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "live-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )

        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [])],
            selectedSessionID: nil,
            recentlyClosed: [fresh, stale]
        )
        let store = SessionStore(restoring: snapshot)

        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.title == "fresh")
    }

    @Test("snapshot() filters expired entries so lazy pruning never re-persists them")
    func snapshotFiltersExpired() throws {
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "stale", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "ghost-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let store = Self.makeStore()
        store.recentlyClosed = [stale]

        #expect(store.snapshot().recentlyClosed.isEmpty)
    }

    @Test("a deliberate user close persists a bare shell even though the quality gate would drop it")
    func userOriginCloseAlwaysPersistsEvenABareShell() throws {
        // Product decision: the isWorthRecording gate exists to keep noisy
        // shell-exit AUTO-closes out of the durable list, not to filter
        // closes the user explicitly asked for. `origin` defaults to `.user`,
        // so every existing explicit close call site (⌘W, ⇧⌘W, palette,
        // group close) keeps this behavior without passing anything.
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .user)

        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.sessionID == bareShell.id)
    }

    @Test("a process-exit auto-close still drops a bare shell — the quality gate applies")
    func processExitOriginCloseStillGatesABareShell() throws {
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .processExit)

        #expect(store.recentlyClosed.isEmpty)
        // Still reopenable via the transient one-slot tier — unchanged.
        #expect(store.lastClosedTransient?.sessionID == bareShell.id)
    }

    @Test("a process-exit auto-close persists a bare shell with an open document")
    func processExitOriginClosePersistsBareShellWithOpenDocument() throws {
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let session = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
                associatedTerminalPaneID: bareShell.activePaneID,
                in: bareShell,
                now: Date()
            )?.session
        )
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])])

        store.closeSession(id: session.id, origin: .processExit)

        #expect(store.recentlyClosed.first?.sessionID == session.id)
    }

    @Test("INT-426 — depth-cap bail preserves BOTH tiers when the entry is shared")
    func depthCapBailDrainsBothTiers() throws {
        // A gate-admitting workspace lands in both tiers. The captured
        // entry's layout is then forced past the depth cap (simulating
        // a tampered cache row that survived JSON-shape validation).
        // The bail must clear BOTH the transient slot and the persisted
        // twin — otherwise the next ⌘+⇧+T hits the same guard and the
        // user perceives the feature as broken for two consecutive
        // keypresses.
        let session = TerminalSession(
            title: "claude", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .claudeCode, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = session.id
        store.closeSession(id: session.id)
        #expect(store.recentlyClosed.count == 1)
        #expect(store.lastClosedTransient != nil)

        // Replace both tiers with a pathological-layout twin sharing
        // the same sessionID. The internal(set) on both properties is
        // there exactly so tests can stage adversarial state without
        // forging closes.
        var pathologicalLayout: TerminalPaneLayout = .pane(
            TerminalPane(title: "deep", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        )
        for _ in 0..<100 {
            pathologicalLayout = .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: pathologicalLayout,
                    second: .pane(
                        TerminalPane(
                            title: "stub",
                            workingDirectory: NSHomeDirectory(),
                            executionPlan: .local
                        ))
                ))
        }
        let twin = RecentlyClosedWorkspace(
            sessionID: store.lastClosedTransient!.sessionID,
            title: "claude",
            isTitleUserEdited: false,
            agentKind: .claudeCode,
            layout: pathologicalLayout,
            activePaneID: UUID(),
            groupID: group.id,
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        store.lastClosedTransient = twin
        store.recentlyClosed = [twin]

        // Depth-guard bails: recovery rows stay so a failed reopen cannot
        // erase the only visible recovery entry.
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.lastClosedTransient == twin)
        #expect(store.recentlyClosed == [twin])
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.recentlyClosed == [twin])
    }

    @Test("INT-426 — transient does NOT persist across SessionSnapshot encode/decode")
    func transientNotPersisted() throws {
        let bareShell = TerminalSession(
            title: "shell", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id
        store.closeSession(id: bareShell.id, origin: .processExit)
        #expect(store.lastClosedTransient != nil)

        // Round-trip through the snapshot: transient must not leak into
        // SessionSnapshot.recentlyClosed (the on-disk JSON).
        let snapshot = store.snapshot()
        #expect(snapshot.recentlyClosed.isEmpty)

        let restored = SessionStore(restoring: snapshot)
        #expect(restored.lastClosedTransient == nil)
        #expect(restored.canReopenClosedWorkspace == false)
    }

    // MARK: - Schema compatibility

    @Test("pre-INT-415 snapshot (no recentlyClosed key) decodes with empty buffer")
    func decodesPreFeatureSnapshot() throws {
        let json = """
            {
              "schemaVersion": 1,
              "groups": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "g",
                  "sessions": []
                }
              ]
            }
            """.data(using: .utf8)!

        let snapshot = try SessionSnapshot.decode(from: json)
        #expect(snapshot.recentlyClosed.isEmpty)
        #expect(snapshot.groups.count == 1)
    }

    @Test("malformed recentlyClosed entry is skipped, rest of snapshot survives")
    func malformedEntryIsIsolated() throws {
        let valid = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "ok",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "ok", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let validData = try JSONEncoder().encode([valid])
        let validJSONFragment = String(data: validData, encoding: .utf8)!
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Build a snapshot with one valid entry and one structurally-broken
        // entry (a string where an object is expected). The tolerant decoder
        // should keep the valid entry.
        let json = """
            {
              "schemaVersion": 1,
              "groups": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "name": "g",
                  "sessions": []
                }
              ],
              "recentlyClosed": ["this should be an object, not a string", \(validJSONFragment)]
            }
            """.data(using: .utf8)!

        let snapshot = try SessionSnapshot.decode(from: json)
        #expect(snapshot.recentlyClosed.count == 1)
        #expect(snapshot.recentlyClosed.first?.title == "ok")
    }

    @Test("captured layout exceeding the depth cap is dropped, not recursed")
    func adversarialDeepLayoutIsDropped() throws {
        // SessionStore.maxRestoredLayoutDepth is fileprivate; bake the cap
        // (64) into the test by going well past it. If the cap ever drops
        // below 100, raise this; if it rises above 100, raise this.
        let deeperThanCap = 100
        var layout: TerminalPaneLayout = .pane(
            TerminalPane(title: "leaf", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        )
        for _ in 0..<deeperThanCap {
            layout = .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: layout,
                    second: .pane(
                        TerminalPane(
                            title: "stub",
                            workingDirectory: NSHomeDirectory(),
                            executionPlan: .local
                        ))
                ))
        }
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "deep",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: layout,
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore(sessionCount: 1)
        let preGroupCount = store.groups[0].sessions.count
        store.recentlyClosed = [entry]

        // Entry stays available without inserting a session.
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.recentlyClosed == [entry])
        #expect(store.groups[0].sessions.count == preGroupCount)
    }

    @Test("reopen runs captured title through the sanitiser (drops RTL override)")
    func reopenSanitisesTitle() throws {
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            // U+202E RIGHT-TO-LEFT OVERRIDE in the middle of a title
            title: "safe\u{202E}danger",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "leaf", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore()
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))
        #expect(!reopened.title.contains("\u{202E}"))
    }
}
