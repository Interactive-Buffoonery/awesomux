import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// Tests for persistence schema bumps after the INT-504 agent-state relocation.
// Current schema is v6; v3 introduced `TerminalPaneLayout.document` (INT-562),
// v4 introduced durable terminal-session IDs (INT-561), and v5 turned document
// leaves into `documentGroup` tab containers with per-tab terminal
// associations (INT-748), and v6 added structured synthetic workspace titles
// (INT-612). Invariants:
//
//  1. `currentSchemaVersion` is 6.
//  2. A legacy v2 terminal-only snapshot round-trips cleanly under v6 (the v1
//     agent-state fold must NOT activate for v2 data — `foldsLegacyAgentState`
//     must stay gated on `schemaVersion < 2`, NOT `< currentSchemaVersion`).
//  3. A v4 snapshot with legacy `.document` leaves migrates: one group, tabs in
//     tree order, associations backfilled from split adjacency.
//  4. A v5 snapshot round-trips shape-stable and does NOT re-backfill a nil
//     association (the migration gate is the literal `< 5`).

@MainActor
@Suite("SessionPersistence — schema migration")
struct SessionPersistenceDocumentTests {

    // MARK: - Schema version constant

    @Test("currentSchemaVersion is 6")
    func currentSchemaIsV6() {
        #expect(SessionSnapshot.currentSchemaVersion == 6)
    }

    // MARK: - Legacy v2 round-trip (fold guard verification)

    /// A v2 snapshot (terminal-only, per-pane agent state) must decode cleanly
    /// under v6. The key risk from the bump: if the fold gate stays at
    /// `schemaVersion < currentSchemaVersion` (dynamic), a v2 file would satisfy
    /// `2 < 6` and the fold would clobber per-pane agent state. The fix moves
    /// the gate to `schemaVersion < 2` (hardcoded v1 threshold).
    @Test("legacy v2 terminal snapshot round-trips unchanged under v6")
    func legacyV2SnapshotStillDecodes() throws {
        try withTemporarySupportDirectory { tempDir in
            let pane = TerminalPane(title: "zsh", workingDirectory: "~", executionPlan: .local)
            let session = TerminalSession(
                title: "s",
                workingDirectory: "~",
                layout: .pane(pane),
                activePaneID: pane.id
            )
            // Encode as v2 explicitly so we're testing the "old file on new build" path.
            let v2Snapshot = SessionSnapshot(
                schemaVersion: 2,
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            )
            let data = try JSONEncoder().encode(v2Snapshot)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(result.store.groups.count == 1)
            #expect(result.store.groups.first?.sessions.count == 1)
            #expect(result.store.groups.first?.sessions.first?.panes.first?.id == pane.id)
        }
    }

    // MARK: - v2 per-pane agent state regression canary (INT-504 / INT-562)

    /// Canary: a v2 snapshot with stray session-level agent keys (a hybrid or
    /// partially-migrated file) must NOT let those keys clobber the per-pane agent
    /// state when loaded through the real `SessionPersistence.load()` path.
    ///
    /// What this guards: `TerminalSession.init(from:)` gates the v1→v2 agent-state
    /// fold on the literal constant `schemaVersion < 2`. If that gate is ever
    /// widened back to `< currentSchemaVersion` (the INT-504 regression pattern),
    /// a v2 file decoded on a current build satisfies `2 < currentSchemaVersion`,
    /// so the fold fires.
    /// When the fold fires AND the file contains stray session-level agent keys
    /// (e.g. `agentKind: "shell"`) that disagree with the per-pane state (e.g.
    /// `agentKind: "Codex"`), `TerminalSession.init` overwrites the active pane's
    /// decoded state with the stale session-level values. This test will FAIL in
    /// that regression scenario.
    ///
    /// Note: the fold only fires when `hasSessionLevelAgentParams` sees a non-nil
    /// session-level key. A clean v2 file (no session-level keys) is immune even
    /// with the wrong gate — the hybrid case is what triggers the actual clobber.
    @Test("v2 per-pane agent state survives round-trip unchanged under v6")
    func v2PerPaneAgentStateSurvivesRoundTripUnchanged() throws {
        try withTemporarySupportDirectory { tempDir in
            // Two panes with distinctive, non-default agent state.
            let codexPane = TerminalPane(
                title: "codex",
                workingDirectory: "~",
                agentKind: .codex,
                agentExecutionState: .waiting,  // non-idle; preserved by restore reducer
                executionPlan: .local
            )
            let claudePane = TerminalPane(
                title: "claude",
                workingDirectory: "~",
                agentKind: .claudeCode,
                agentExecutionState: .waiting,
                executionPlan: .local
            )
            let session = TerminalSession(
                title: "agents",
                workingDirectory: "~",
                layout: .split(TerminalSplit(
                    orientation: .vertical,
                    first: .pane(codexPane),
                    second: .pane(claudePane)
                )),
                activePaneID: codexPane.id
            )
            // Encode as v2 snapshot, then inject stray session-level agent keys
            // that DISAGREE with the active pane's own per-pane state. This is the
            // "hybrid/hand-edited" shape that triggers the fold clobber when the
            // gate is `< currentSchemaVersion` instead of the correct `< 2`.
            let v2Snapshot = SessionSnapshot(
                schemaVersion: 2,
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            )
            var dict = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(v2Snapshot)
            ) as! [String: Any]

            // Inject stray session-level keys into the session dict — they
            // disagree with the active (codex/waiting) pane's own decoded state.
            if var groups = dict["groups"] as? [[String: Any]],
               var sessions = groups[0]["sessions"] as? [[String: Any]] {
                sessions[0]["agentKind"] = "shell"
                sessions[0]["agentExecutionState"] = "idle"
                groups[0]["sessions"] = sessions
                dict["groups"] = groups
            }

            let data = try JSONSerialization.data(withJSONObject: dict)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            let restoredSession = result.store.groups.first?.sessions.first

            // Both pane IDs must survive intact.
            #expect(restoredSession?.layout.pane(id: codexPane.id) != nil)
            #expect(restoredSession?.layout.pane(id: claudePane.id) != nil)

            // Per-pane state must win over the stray session-level keys. If the
            // fold gate regresses to `< currentSchemaVersion`, the fold fires on
            // v2 data under the current schema and replaces codex/waiting with shell/idle here.
            #expect(restoredSession?.layout.pane(id: codexPane.id)?.agentKind == .codex)
            #expect(restoredSession?.layout.pane(id: codexPane.id)?.agentExecutionState == .waiting)
            #expect(restoredSession?.layout.pane(id: claudePane.id)?.agentKind == .claudeCode)
            #expect(restoredSession?.layout.pane(id: claudePane.id)?.agentExecutionState == .waiting)
        }
    }

    // MARK: - Document viewer round-trip

    /// A session whose layout contains a document group nested in a split (the
    /// only valid shape — a group is never a layout root) must encode at the
    /// current schema and round-trip back to the same layout. The tab keeps a
    /// deliberately NIL association: v5 data must not get a fresh adjacency
    /// backfill on load (the migration gate is the literal `< 5`).
    @Test("split layout containing a document group round-trips at current schema")
    func documentLayoutSurvivesSnapshotRoundTrip() throws {
        try withTemporarySupportDirectory { tempDir in
            let terminal = TerminalPane(title: "zsh", workingDirectory: "~", executionPlan: .local)
            let doc = DocumentPane(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("notes.md"),
                title: "notes.md"
            )
            // Document groups are always nested inside a split — never the layout root.
            let layout = TerminalPaneLayout.split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
            ))
            let session = TerminalSession(
                title: "s",
                workingDirectory: "~",
                layout: layout,
                activePaneID: terminal.id
            )
            let snapshot = SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            )
            let data = try JSONEncoder().encode(snapshot)

            // Confirm the encoded snapshot carries the current schema version.
            let versionPeek = try JSONDecoder().decode(SchemaVersionForTest.self, from: data)
            #expect(versionPeek.schemaVersion == 6)

            // Write and reload via the real persistence path.
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            let restoredSession = result.store.groups.first?.sessions.first
            #expect(restoredSession?.layout == layout)
            // Gate canary: nil association is legitimate v5 data (fail-closed)
            // and must survive the load without an adjacency re-backfill.
            let restoredGroup = restoredSession?.layout.firstDocumentGroup
            #expect(restoredGroup?.tabs.first?.associatedTerminalPaneID == nil)
        }
    }

    // MARK: - v5 → v6 synthetic title migration

    @Test("v5 synthetic titles gain structured metadata through the real load path")
    func v5SyntheticTitlesGainMetadata() throws {
        try withTemporarySupportDirectory { tempDir in
            let session = TerminalSession(
                title: "shell 4",
                workingDirectory: "~",
                agentKind: .shell
            )
            let closedPane = TerminalPane(title: "shell", workingDirectory: "/work", executionPlan: .local)
            let closed = RecentlyClosedWorkspace(
                sessionID: UUID(),
                title: "shell 5",
                isTitleUserEdited: false,
                agentKind: .shell,
                layout: .pane(closedPane),
                activePaneID: closedPane.id,
                groupID: UUID(),
                groupName: "main",
                groupRemote: nil,
                indexInGroup: 0,
                closedAt: Date()
            )
            let snapshot = SessionSnapshot(
                schemaVersion: 5,
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id,
                recentlyClosed: [closed]
            )
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(
                result.store.session(id: session.id)?.syntheticTitle
                    == SyntheticSessionTitle(agentKind: .shell, index: 4)
            )
            #expect(
                result.store.recentlyClosed.first?.syntheticTitle
                    == SyntheticSessionTitle(agentKind: .shell, index: 5)
            )
        }
    }

    // MARK: - v4 → v5 migration through the real load path

    /// A v4 snapshot with two legacy `.document` leaves in nested splits, each
    /// beside a DIFFERENT terminal, must load as ONE group with two tabs whose
    /// associations point at their original adjacent terminals.
    @Test("v4 snapshot with nested document leaves migrates to one backfilled group")
    func v4DocumentLeavesMigrateToOneGroup() throws {
        try withTemporarySupportDirectory { tempDir in
            let t1 = TerminalPane(title: "t1", workingDirectory: "~", executionPlan: .local)
            let t2 = TerminalPane(title: "t2", workingDirectory: "~", executionPlan: .local)
            let sessionID = UUID()
            let docAID = UUID()
            let docBID = UUID()
            // Hand-build v4 JSON: the current encoder can no longer produce the
            // legacy `document` leaf key.
            func legacyDoc(_ id: UUID, _ name: String) -> String {
                """
                {"document":{"_0":{"id":"\(id.uuidString)","fileURL":"file:///tmp/\(name)","title":"\(name)","scrollOffset":0}}}
                """
            }
            let paneJSON = try [t1, t2].map {
                String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
            }
            let json = """
            {
              "schemaVersion": 4,
              "groups": [{
                "id": "\(UUID().uuidString)",
                "name": "main",
                "sessions": [{
                  "id": "\(sessionID.uuidString)",
                  "title": "s",
                  "workingDirectory": "~",
                  "isTitleUserEdited": false,
                  "layout": {"split":{"_0":{
                    "id": "\(UUID().uuidString)",
                    "orientation": "horizontal",
                    "firstFraction": 0.5,
                    "first": {"split":{"_0":{
                      "id": "\(UUID().uuidString)",
                      "orientation": "vertical",
                      "firstFraction": 0.6,
                      "first": {"pane":{"_0":\(paneJSON[0])}},
                      "second": \(legacyDoc(docAID, "a.md"))
                    }}},
                    "second": {"split":{"_0":{
                      "id": "\(UUID().uuidString)",
                      "orientation": "vertical",
                      "firstFraction": 0.6,
                      "first": {"pane":{"_0":\(paneJSON[1])}},
                      "second": \(legacyDoc(docBID, "b.md"))
                    }}}
                  }}},
                  "activePaneID": "\(t1.id.uuidString)"
                }]
              }],
              "selectedSessionID": "\(sessionID.uuidString)"
            }
            """
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            let restoredSession = result.store.groups.first?.sessions.first
            let group = restoredSession?.layout.firstDocumentGroup
            #expect(group?.tabs.map(\.id) == [docAID, docBID], "one group, tabs in tree order")
            #expect(group?.selectedTabID == docAID)
            #expect(group?.tab(id: docAID)?.associatedTerminalPaneID == t1.id)
            #expect(group?.tab(id: docBID)?.associatedTerminalPaneID == t2.id)
            // Both terminals survive; the second document's split collapsed.
            #expect(restoredSession?.layout.paneIDs == [t1.id, t2.id])
        }
    }

    /// Recently-closed entries persist raw layouts inside the same snapshot but
    /// decode outside `TerminalSession.init(from:)` — they need their own
    /// version-gated migration (INT-748 review finding). A v4 entry with two
    /// legacy `.document` leaves must reopen-ready decode as ONE folded group
    /// with adjacency-backfilled associations, not a multi-group zombie.
    @Test("v4 recently-closed entry migrates its document leaves on decode")
    func v4RecentlyClosedEntryMigratesDocuments() throws {
        try withTemporarySupportDirectory { tempDir in
            let t1 = TerminalPane(title: "t1", workingDirectory: "~", executionPlan: .local)
            let t2 = TerminalPane(title: "t2", workingDirectory: "~", executionPlan: .local)
            let docAID = UUID()
            let docBID = UUID()
            func legacyDoc(_ id: UUID, _ name: String) -> String {
                """
                {"document":{"_0":{"id":"\(id.uuidString)","fileURL":"file:///tmp/\(name)","title":"\(name)","scrollOffset":0}}}
                """
            }
            let paneJSON = try [t1, t2].map {
                String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
            }
            let liveSession = TerminalSession(
                title: "live",
                workingDirectory: "~",
                layout: .pane(TerminalPane(title: "zsh", workingDirectory: "~", executionPlan: .local))
            )
            let liveSessionJSON = String(
                decoding: try JSONEncoder().encode(liveSession),
                as: UTF8.self
            )
            let json = """
            {
              "schemaVersion": 4,
              "groups": [{
                "id": "\(UUID().uuidString)",
                "name": "main",
                "sessions": [\(liveSessionJSON)]
              }],
              "selectedSessionID": "\(liveSession.id.uuidString)",
              "recentlyClosed": [{
                "sessionID": "\(UUID().uuidString)",
                "title": "closed",
                "isTitleUserEdited": false,
                "agentKind": "Shell",
                "layout": {"split":{"_0":{
                  "id": "\(UUID().uuidString)",
                  "orientation": "horizontal",
                  "firstFraction": 0.5,
                  "first": {"split":{"_0":{
                    "id": "\(UUID().uuidString)",
                    "orientation": "vertical",
                    "firstFraction": 0.6,
                    "first": {"pane":{"_0":\(paneJSON[0])}},
                    "second": \(legacyDoc(docAID, "a.md"))
                  }}},
                  "second": {"split":{"_0":{
                    "id": "\(UUID().uuidString)",
                    "orientation": "vertical",
                    "firstFraction": 0.6,
                    "first": {"pane":{"_0":\(paneJSON[1])}},
                    "second": \(legacyDoc(docBID, "b.md"))
                  }}}
                }}},
                "activePaneID": "\(t1.id.uuidString)",
                "groupID": "\(UUID().uuidString)",
                "groupName": "main",
                "indexInGroup": 0,
                "closedAt": \(Date().timeIntervalSinceReferenceDate)
              }]
            }
            """
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            let entry = result.store.recentlyClosed.first
            let group = entry?.layout.firstDocumentGroup
            #expect(group?.tabs.map(\.id) == [docAID, docBID], "one folded group, tabs in tree order")
            #expect(group?.tab(id: docAID)?.associatedTerminalPaneID == t1.id)
            #expect(group?.tab(id: docBID)?.associatedTerminalPaneID == t2.id)
            #expect(entry?.layout.paneIDs == [t1.id, t2.id])
        }
    }

    // MARK: - C1: doc-only root is quarantined, not a crash-loop

    /// A hand-edited (or corrupt) snapshot whose session layout is a bare
    /// `.document(...)` root must NOT crash the app. `firstPane` on a
    /// `.document` layout returns nil; prior to C1 that reached
    /// `firstPaneID`'s `preconditionFailure` inside the Codable decode path,
    /// BELOW `SessionPersistence.load()`'s `do/catch` — crash-looping every
    /// launch. The fix makes `TerminalSession.init(from:)` throw a
    /// `DecodingError` instead, which the outer `catch` catches and routes to
    /// quarantine. This test confirms: no crash, bad session dropped,
    /// archivedSnapshot warning surfaced.
    @Test("doc-only root layout is quarantined without crashing")
    func docOnlyRootLayoutIsQuarantinedNotCrashed() throws {
        try withTemporarySupportDirectory { tempDir in
            // Build the corrupt snapshot JSON by hand — encoding a
            // TerminalSession with a `.document` layout root would call the
            // very memberwise init that traps; bypass it entirely.
            let sessionID = UUID().uuidString
            let docID = UUID().uuidString
            let groupID = UUID().uuidString
            let json = """
            {
              "schemaVersion": 5,
              "groups": [{
                "id": "\(groupID)",
                "name": "main",
                "sessions": [{
                  "id": "\(sessionID)",
                  "title": "bad",
                  "workingDirectory": "~",
                  "isTitleUserEdited": false,
                  "layout": {
                    "document": {
                      "id": "\(docID)",
                      "fileURL": "file:///tmp/bad.md",
                      "title": "bad.md",
                      "scrollOffset": 0
                    }
                  },
                  "activePaneID": "\(UUID().uuidString)"
                }]
              }],
              "selectedSessionID": "\(sessionID)"
            }
            """
            let data = Data(json.utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            // Must return — NOT crash — with an archivedSnapshot recovery warning.
            let result = SessionPersistence.load()

            guard case .archivedSnapshot = result.recoveryWarning?.kind else {
                Issue.record(
                    "expected archivedSnapshot recovery warning for doc-only layout root, got: \(String(describing: result.recoveryWarning))"
                )
                return
            }
            // The corrupt session must NOT appear in the restored store.
            // `SessionPersistence.load()` quarantine path returns a fresh
            // default SessionStore(), not the bad snapshot's sessions.
            let allSessionIDs = result.store.groups.flatMap(\.sessions).map(\.id.uuidString)
            #expect(!allSessionIDs.contains(sessionID))
        }
    }

    // MARK: - Helpers

    private func withTemporarySupportDirectory(_ operation: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "awesomux-document-persistence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try SessionPersistence.withTemporarySupportDirectory(tempDir) {
            try operation(tempDir)
        }
    }
}

/// Minimal decodable to peek the schemaVersion from encoded snapshot bytes
/// without importing or re-exposing the private `SchemaVersionPeek` from
/// `SessionPersistence.swift`.
private struct SchemaVersionForTest: Decodable {
    let schemaVersion: Int
}
