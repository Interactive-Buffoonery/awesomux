import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("INT-504 snapshot migration")
struct SessionSnapshotMigrationTests {
    @Test("a v1 snapshot folds session-level agent state onto the active pane")
    func migratesLegacySessionStateOntoActivePane() throws {
        // Build a modern single-pane session, then rewrite its JSON into the v1
        // shape: hoist agent state up to the session and strip it from the pane,
        // exactly as a pre-relocation snapshot stored it.
        let pane = TerminalPane(id: UUID(), title: "codex", workingDirectory: "~", executionPlan: .local)
        let modern = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modern)
        ) as! [String: Any]

        dict["agentKind"] = "Codex"
        dict["agentExecutionState"] = "thinking"
        dict["attentionReason"] = "permissionPrompt"
        dict["unreadNotificationCount"] = 2
        if var layout = dict["layout"] as? [String: Any],
           var paneDict = layout["pane"] as? [String: Any] {
            for key in ["agentKind", "agentExecutionState", "attentionReason", "unreadNotificationCount"] {
                paneDict.removeValue(forKey: key)
            }
            layout["pane"] = paneDict
            dict["layout"] = layout
        }

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        let active = decoded.activePane
        #expect(active?.agentKind == .codex)
        #expect(active?.agentExecutionState == .thinking)
        // R5: a live v1 permission prompt folds onto the active pane so it
        // survives the bump (the restore reducer keeps `.permissionPrompt`).
        // Unread is still NOT carried across the bump.
        #expect(active?.attentionReason == .permissionPrompt)
        #expect(active?.unreadNotificationCount == 0)
    }

    @Test("a v2 multi-pane snapshot round-trips per-pane agent state")
    func multiPaneRoundTripsPerPaneState() throws {
        let codex = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            unreadNotificationCount: 3,
            executionPlan: .local
        )
        let claude = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .permissionPrompt,
            unreadNotificationCount: 1,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(codex),
                second: .pane(claude)
            )),
            activePaneID: codex.id
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        let decodedCodex = decoded.layout.pane(id: codex.id)
        let decodedClaude = decoded.layout.pane(id: claude.id)
        #expect(decodedCodex?.agentKind == .codex)
        #expect(decodedCodex?.agentExecutionState == .thinking)
        #expect(decodedCodex?.unreadNotificationCount == 3)
        #expect(decodedClaude?.agentKind == .claudeCode)
        #expect(decodedClaude?.attentionReason == .permissionPrompt)
        #expect(decodedClaude?.unreadNotificationCount == 1)
    }

    @Test("a stray session-level key does not zero the active pane's decoded unread")
    func straySessionKeyDoesNotZeroDecodedUnread() throws {
        // M3: a v2 snapshot whose active pane carries its own decoded unread, but
        // which also has a leftover session-level agent key (a partially-migrated
        // or hand-edited file), must NOT let the legacy fold clobber that decoded
        // per-pane value back to the default 0.
        let codex = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            unreadNotificationCount: 3,
            executionPlan: .local
        )
        let claude = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            unreadNotificationCount: 1,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(codex),
                second: .pane(claude)
            )),
            activePaneID: codex.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as! [String: Any]
        dict["agentExecutionState"] = "running"

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        #expect(decoded.layout.pane(id: codex.id)?.unreadNotificationCount == 3)
        #expect(decoded.layout.pane(id: claude.id)?.unreadNotificationCount == 1)
    }

    @Test("a v1 snapshot folds session-level agent identity onto the active pane")
    func v1SnapshotFoldsAgentIdentityOntoActivePane() throws {
        // The legacy v1 policy folds session-level agent IDENTITY (kind +
        // execution state) onto the active pane. A bare `TerminalSession` decode
        // (no schema-version in userInfo) defaults to v1, so this migration
        // still fires. Distinct from the unread/activity clobber M3 fixed.
        let active = TerminalPane(
            title: "active", workingDirectory: "~", agentKind: .shell, agentExecutionState: .idle,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(active),
            activePaneID: active.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as! [String: Any]
        dict["agentKind"] = "Codex"
        dict["agentExecutionState"] = "thinking"

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        #expect(decoded.activePane?.agentKind == .codex)
        #expect(decoded.activePane?.agentExecutionState == .thinking)
    }

    @MainActor
    @Test("a restored v1 stale agent identity clears after migration")
    func restoredV1StaleAgentIdentityClearsAfterMigration() throws {
        let pane = TerminalPane(
            title: "active",
            workingDirectory: "~",
            agentKind: .shell,
            agentExecutionState: .idle,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)
        ) as! [String: Any]
        dict["schemaVersion"] = 1
        var groups = dict["groups"] as! [[String: Any]]
        var sessions = groups[0]["sessions"] as! [[String: Any]]
        sessions[0]["agentKind"] = "Codex"
        sessions[0]["agentExecutionState"] = "thinking"
        groups[0]["sessions"] = sessions
        dict["groups"] = groups

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let store = SessionStore(restoring: decoded)

        #expect(store.selectedSession?.activePane?.agentKind == .shell)
        #expect(store.selectedSession?.activePane?.agentExecutionState == .idle)
        #expect(store.selectedSession?.activePane?.attentionReason == nil)
    }

    @Test("a v2 snapshot trusts decoded pane state over a stray session-level key")
    func v2SnapshotTrustsPaneStateOverStraySessionKey() throws {
        // M3 (INT-504 review): a v2 snapshot stores agent state PER PANE. A stray
        // session-level `agentKind`/`agentExecutionState` (a hybrid or hand-edited
        // file) must NOT clobber the pane's own decoded identity — v2 must trust
        // per-pane state. The fold is gated OFF when the snapshot decodes at the
        // current schema version, threaded in via `userInfo`.
        let codex = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let claude = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(codex),
                second: .pane(claude)
            )),
            activePaneID: codex.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as! [String: Any]
        // Stray session-level keys disagreeing with the active pane's own state.
        dict["agentKind"] = "shell"
        dict["agentExecutionState"] = "idle"

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = SessionSnapshot.currentSchemaVersion
        let decoded = try decoder.decode(TerminalSession.self, from: data)

        // v2 wins: the active pane keeps its own decoded codex/thinking, not the
        // stray shell/idle session-level keys.
        #expect(decoded.layout.pane(id: codex.id)?.agentKind == .codex)
        #expect(decoded.layout.pane(id: codex.id)?.agentExecutionState == .thinking)
        #expect(decoded.layout.pane(id: claude.id)?.agentKind == .claudeCode)
        #expect(decoded.layout.pane(id: claude.id)?.agentExecutionState == .waiting)
    }

    @Test("a legacy needsAttention agentState clears to nil, not AttentionReason.unknown")
    func legacyNeedsAttentionAgentStateClearsToNil() throws {
        // M3 / R5: v1 stored one display state on the session. A stale
        // `needsAttention` must clear on the bump, NOT resurrect as
        // `AttentionReason.unknown` via the `agentState` fold path.
        let pane = TerminalPane(id: UUID(), title: "codex", workingDirectory: "~", executionPlan: .local)
        let modern = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modern)
        ) as! [String: Any]
        dict["agentState"] = "needsAttention"
        if var layout = dict["layout"] as? [String: Any],
           var paneDict = layout["pane"] as? [String: Any] {
            for key in ["agentExecutionState", "attentionReason", "unreadNotificationCount"] {
                paneDict.removeValue(forKey: key)
            }
            layout["pane"] = paneDict
            dict["layout"] = layout
        }

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        #expect(decoded.activePane?.attentionReason == nil)
    }

    @Test("a garbage agentExecutionState decodes to idle instead of throwing")
    func toleratesGarbageExecutionState() throws {
        // M5: an unknown/forward-version/hand-edited execution-state raw value
        // must fall back to `.idle`, not throw — otherwise one corrupt pane
        // fails the entire snapshot decode into quarantine.
        let pane = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(pane)
        ) as! [String: Any]
        dict["agentExecutionState"] = "wat-is-this"

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        #expect(decoded.agentExecutionState == .idle)
        #expect(decoded.agentKind == .codex)
    }

    @Test("one corrupt inactive pane does not fail the whole workspace decode")
    func corruptInactivePaneDoesNotFailWorkspaceDecode() throws {
        let active = TerminalPane(title: "active", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let inactive = TerminalPane(
            title: "inactive",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(active),
                second: .pane(inactive)
            )),
            activePaneID: active.id
        )
        // Corrupt only the inactive pane's execution state. The active pane is a
        // shell (`.idle`), so `thinking` appears solely on the inactive `.codex`
        // pane — a targeted string swap is robust to the synthesized enum's
        // `_0`-wrapped layout JSON.
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(encoded.components(separatedBy: "\"thinking\"").count == 2)
        let corrupted = encoded.replacingOccurrences(
            of: "\"thinking\"",
            with: "\"corrupted-by-hand\""
        )

        let data = Data(corrupted.utf8)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        #expect(decoded.layout.pane(id: inactive.id)?.agentExecutionState == .idle)
        #expect(decoded.layout.pane(id: active.id)?.agentExecutionState == .idle)
        #expect(decoded.layout.paneCount == 2)
    }

    @Test("the snapshot schema version is bumped for the relocation")
    func schemaVersionBumped() {
        // Tripwire: bumped to 5 by INT-748 (document tabs + terminal associations).
        // Update this literal on every schema bump — it forces a conscious review
        // of the version-gated migration folds (see TerminalSession's `< 2` and
        // `< 5` gates).
        #expect(SessionSnapshot.currentSchemaVersion == 6)
    }

    @Test("v6 sessions round-trip structured synthetic title metadata")
    func syntheticTitleMetadataRoundTrips() throws {
        let session = TerminalSession(
            title: "shell 3",
            workingDirectory: "~",
            syntheticTitle: SyntheticSessionTitle(agentKind: .shell, index: 3),
            agentKind: .shell
        )

        let data = try JSONEncoder().encode(session)
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 6
        let decoded = try decoder.decode(TerminalSession.self, from: data)

        #expect(decoded.syntheticTitle == SyntheticSessionTitle(agentKind: .shell, index: 3))
        #expect(decoded.title == "shell 3")
    }

    @Test("v5 infers metadata only for unedited canonical synthetic titles")
    func v5InfersSyntheticTitleMetadata() throws {
        let automatic = TerminalSession(title: "shell 4", workingDirectory: "~", agentKind: .shell)
        let edited = TerminalSession(
            title: "shell 5",
            workingDirectory: "~",
            isTitleUserEdited: true,
            agentKind: .shell
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 5

        let decodedAutomatic = try decoder.decode(
            TerminalSession.self,
            from: encoder.encode(automatic)
        )
        let decodedEdited = try decoder.decode(
            TerminalSession.self,
            from: encoder.encode(edited)
        )

        #expect(decodedAutomatic.syntheticTitle == SyntheticSessionTitle(agentKind: .shell, index: 4))
        #expect(decodedEdited.syntheticTitle == nil)
    }

    @Test("v5 inference keeps the generating kind when the active agent changed")
    func v5InferenceUsesCanonicalTitleKind() throws {
        let legacy = TerminalSession(
            title: "shell 6",
            workingDirectory: "~",
            agentKind: .codex
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 5

        let decoded = try decoder.decode(
            TerminalSession.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.activeAgentKind == .codex)
        #expect(decoded.syntheticTitle == SyntheticSessionTitle(agentKind: .shell, index: 6))
    }

    @Test("v5 inference does not normalize titles that only resemble generated titles")
    func v5InferenceRequiresCanonicalSpelling() throws {
        let legacy = TerminalSession(
            title: "shell 06",
            workingDirectory: "~",
            agentKind: .shell
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = 5

        let decoded = try decoder.decode(
            TerminalSession.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.title == "shell 06")
        #expect(decoded.syntheticTitle == nil)
    }

    @MainActor
    @Test("restore keeps per-pane kind, preserves a live prompt, clears unread")
    func restorePreservesKindAndLivePrompt() throws {
        let codex = TerminalPane(
            title: "codex",
            workingDirectory: "~/work",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt,
            unreadNotificationCount: 5,
            executionPlan: .local
        )
        let claude = TerminalPane(
            title: "claude",
            workingDirectory: "~/work",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~/work",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(codex),
                second: .pane(claude)
            )),
            activePaneID: codex.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)
        let restored = store.session(id: session.id)

        // Live provider chrome is preserved for the still-blocking prompt and
        // the explicit `.waiting` pane; unread is still cleared.
        #expect(restored?.layout.pane(id: codex.id)?.agentKind == .codex)
        #expect(restored?.layout.pane(id: codex.id)?.agentExecutionState == .idle)
        #expect(restored?.layout.pane(id: codex.id)?.attentionReason == .permissionPrompt)
        #expect(restored?.layout.pane(id: codex.id)?.unreadNotificationCount == 0)
        #expect(restored?.layout.pane(id: codex.id)?.agentState == .needsAttention)
        #expect(restored?.layout.pane(id: claude.id)?.agentKind == .claudeCode)
        #expect(restored?.layout.pane(id: claude.id)?.agentExecutionState == .waiting)
        #expect(restored?.unreadNotificationCount == 0)
    }

    @MainActor
    @Test("restore clears stale current-schema per-pane agent identity")
    func restoreClearsStaleCurrentSchemaPerPaneAgentIdentity() throws {
        let codex = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            layout: .pane(codex),
            activePaneID: codex.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let store = SessionStore(restoring: decoded)

        #expect(store.selectedSession?.activePane?.agentKind == .shell)
        #expect(store.selectedSession?.activePane?.agentExecutionState == .idle)
        #expect(store.selectedSession?.activePane?.attentionReason == nil)
        #expect(store.selectedSession?.effectiveChromeState == .idle)
    }

    @MainActor
    @Test("restore preserves userInputRequired and permissionPrompt, clears stale reasons")
    func restorePreservesLivePromptsClearsStale() throws {
        // R5: only a live, still-blocking prompt survives relaunch. A bell, a
        // desktop notification, or a process error is stale runtime noise.
        func pane(_ kind: AgentKind, _ reason: AttentionReason) -> TerminalPane {
            TerminalPane(
                title: "p", workingDirectory: "~", agentKind: kind, attentionReason: reason,
                executionPlan: .local
            )
        }
        let userInput = pane(.codex, .userInputRequired)
        let permission = pane(.claudeCode, .permissionPrompt)
        let bell = pane(.shell, .bell)
        let processError = pane(.codex, .processError)
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .split(TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(userInput),
                    second: .pane(permission)
                )),
                second: .split(TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(bell),
                    second: .pane(processError)
                ))
            )),
            activePaneID: userInput.id
        )
        let store = SessionStore(restoring: SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        ))
        let restored = store.session(id: session.id)

        #expect(restored?.layout.pane(id: userInput.id)?.attentionReason == .userInputRequired)
        #expect(restored?.layout.pane(id: permission.id)?.attentionReason == .permissionPrompt)
        #expect(restored?.layout.pane(id: bell.id)?.attentionReason == nil)
        #expect(restored?.layout.pane(id: processError.id)?.attentionReason == nil)
    }

    @MainActor
    @Test("a v1 session-level permission prompt restores badged on the active pane")
    func v1SessionLevelPromptRestoresBadged() throws {
        // R5 end-to-end: a pre-relocation snapshot that stored its prompt at the
        // session level must fold onto the active pane AND survive the restore
        // reducer, so the workspace comes back needing attention.
        let pane = TerminalPane(id: UUID(), title: "codex", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "codex", workingDirectory: "~", layout: .pane(pane), activePaneID: pane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)
        ) as! [String: Any]
        dict["schemaVersion"] = 1
        var groups = dict["groups"] as! [[String: Any]]
        var sessions = groups[0]["sessions"] as! [[String: Any]]
        sessions[0]["agentKind"] = "Codex"
        sessions[0]["attentionReason"] = "userInputRequired"
        groups[0]["sessions"] = sessions
        dict["groups"] = groups

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let store = SessionStore(restoring: decoded)

        let restored = store.groups.first?.sessions.first
        #expect(restored?.activePane?.attentionReason == .userInputRequired)
        #expect(restored?.needsAcknowledgement == true)
    }

    @MainActor
    @Test("a restored live prompt is row-badged, dock-quiet, and acknowledgeable")
    func restoredPromptIsAcknowledgeableNotStuck() {
        // R5 coherence (Codex): a preserved prompt restores the ROW needs-attention
        // state but NOT a dock unread count (unread is dropped), and it is cleared
        // by the normal ack path — it is not permanently stuck.
        let pane = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .userInputRequired, unreadNotificationCount: 4,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws", workingDirectory: "~", layout: .pane(pane), activePaneID: pane.id
        )
        let store = SessionStore(restoring: SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        ))
        guard let id = store.groups.first?.sessions.first?.id else {
            Issue.record("no restored session")
            return
        }

        #expect(store.session(id: id)?.needsAcknowledgement == true)
        // The stale unread count is dropped — only the row/ack state survives.
        #expect(store.unreadNotificationTotal == 0)

        store.acknowledgeAllPanes(in: id)
        #expect(store.session(id: id)?.needsAcknowledgement == false)
    }
}
