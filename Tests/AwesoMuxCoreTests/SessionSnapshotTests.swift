import XCTest
import Foundation
@testable import AwesoMuxCore

final class SessionSnapshotTests: XCTestCase {
    func testEncodesCurrentSchemaVersion() throws {
        let snapshot = SessionSnapshot(groups: [], selectedSessionID: nil)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["schemaVersion"] as? Int, SessionSnapshot.currentSchemaVersion)
    }

    func testTerminalSessionIDFitsAmxSessionNameLimit() throws {
        let id = TerminalSessionID.generate()

        XCTAssertLessThanOrEqual(
            id.rawValue.utf8.count,
            TerminalSessionID.maxAmxSessionNameUTF8Bytes
        )
        XCTAssertTrue(TerminalSessionID.isValid(id.rawValue))
        XCTAssertNil(TerminalSessionID(rawValue: "--help"))
    }

    func testTerminalPanePersistsTerminalSessionID() throws {
        let terminalSessionID = try XCTUnwrap(
            TerminalSessionID(rawValue: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        )
        let pane = TerminalPane(
            terminalSessionID: terminalSessionID,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "private-backend-payload"),
            title: "zsh",
            workingDirectory: "~"
        )

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        XCTAssertEqual(decoded.terminalSessionID, terminalSessionID)
        XCTAssertEqual(decoded.terminalBackendMetadata.rawValue, "private-backend-payload")
    }

    func testLegacyTerminalPaneMintsTerminalSessionID() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "zsh",
          "isTitleUserEdited": false,
          "workingDirectory": "~",
          "agentKind": "Shell",
          "agentExecutionState": "idle",
          "unreadNotificationCount": 0
        }
        """

        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))

        XCTAssertLessThanOrEqual(
            decoded.terminalSessionID.rawValue.utf8.count,
            TerminalSessionID.maxAmxSessionNameUTF8Bytes
        )
        XCTAssertTrue(TerminalSessionID.isValid(decoded.terminalSessionID.rawValue))
    }

    @MainActor
    func testRestoreReassignsDuplicateTerminalSessionIDs() throws {
        let sharedID = try XCTUnwrap(
            TerminalSessionID(rawValue: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        )
        let first = TerminalPane(
            terminalSessionID: sharedID,
            title: "first",
            workingDirectory: "~"
        )
        let second = TerminalPane(
            terminalSessionID: sharedID,
            title: "second",
            workingDirectory: "~"
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: first.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)
        let restoredFirst = try XCTUnwrap(store.selectedSession?.layout.pane(id: first.id))
        let restoredSecond = try XCTUnwrap(store.selectedSession?.layout.pane(id: second.id))

        XCTAssertEqual(restoredFirst.terminalSessionID, sharedID)
        XCTAssertNotEqual(restoredSecond.terminalSessionID, sharedID)
        XCTAssertNotEqual(restoredFirst.terminalSessionID, restoredSecond.terminalSessionID)
        XCTAssertEqual(restoredSecond.terminalBackendMetadata, .empty)
    }

    func testRejectsFutureSchemaVersionReportsVersions() {
        let futureVersion = SessionSnapshot.currentSchemaVersion + 1
        let json = """
        {
          "schemaVersion": \(futureVersion),
          "groups": [],
          "selectedSessionID": null
        }
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        ) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                XCTFail("Expected dataCorrupted, got \(error)")
                return
            }
            XCTAssertEqual(
                context.debugDescription,
                "Unsupported future session snapshot schema version: found \(futureVersion), current \(SessionSnapshot.currentSchemaVersion)."
            )
        }
    }

    @MainActor
    func testWorkspaceGroupColorRoundTripsThroughJSONAndRestore() throws {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(
                    name: "awesoMux",
                    color: .yellow,
                    sessions: [session]
                )
            ],
            selectedSessionID: session.id
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = SessionStore(restoring: decoded)

        XCTAssertEqual(decoded.groups.first?.color, .yellow)
        XCTAssertEqual(restored.groups.first?.color, .yellow)
    }

    func testLegacyWorkspaceGroupColorsStillDecode() throws {
        for color in [WorkspaceGroupColor.sky, .lavender] {
            let groupID = UUID()
            let json = """
            {
              "schemaVersion": \(SessionSnapshot.currentSchemaVersion),
              "groups": [
                {
                  "id": "\(groupID.uuidString)",
                  "name": "awesoMux",
                  "color": "\(color.rawValue)",
                  "sessions": []
                }
              ],
              "selectedSessionID": null
            }
            """

            let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

            XCTAssertEqual(decoded.groups.first?.color, color)
        }
    }

    func testUnknownWorkspaceGroupColorDecodesAsNil() throws {
        let groupID = UUID()
        let json = """
        {
          "schemaVersion": \(SessionSnapshot.currentSchemaVersion),
          "groups": [
            {
              "id": "\(groupID.uuidString)",
              "name": "awesoMux",
              "color": "ultraviolet",
              "sessions": []
            }
          ],
          "selectedSessionID": null
        }
        """

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(decoded.groups.first?.color)
    }

    func testMalformedWorkspaceGroupColorShapeDecodesAsNil() throws {
        let groupID = UUID()
        let json = """
        {
          "schemaVersion": \(SessionSnapshot.currentSchemaVersion),
          "groups": [
            {
              "id": "\(groupID.uuidString)",
              "name": "awesoMux",
              "color": { "unexpected": "shape" },
              "sessions": []
            }
          ],
          "selectedSessionID": null
        }
        """

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(decoded.groups.first?.color)
    }

    func testRemoteTargetRoundTrips() throws {
        let group = SessionGroup(
            id: UUID(), name: "Box", color: nil,
            remote: RemoteTarget(user: "ed", host: "box"),
            sessions: []
        )
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(SessionGroup.self, from: data)
        XCTAssertEqual(decoded.remote, RemoteTarget(user: "ed", host: "box"))
    }

    func testDecodesLegacyGroupWithoutRemoteKeyAsNil() throws {
        // A snapshot written before this field existed has no "remote" key.
        let json = #"{"id":"\#(UUID().uuidString)","name":"Old","sessions":[]}"#
        let decoded = try JSONDecoder().decode(SessionGroup.self, from: Data(json.utf8))
        XCTAssertNil(decoded.remote)
    }

    func testOmitsRemoteKeyWhenNil() throws {
        let group = SessionGroup(id: UUID(), name: "Local", color: nil, sessions: [])
        let json = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
        XCTAssertFalse(json.contains("remote"))
    }

    @MainActor
    func testRestoringSessionClampsFinishedAgentStateToIdle() {
        let finishedSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .done
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [finishedSession])],
            selectedSessionID: finishedSession.id
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSession?.agentState, .idle)
    }

    @MainActor
    func testRestoringWaitingSessionPreservesWaitingAgentStateThroughJSON() throws {
        // Round-trips through JSONEncoder/JSONDecoder rather than handing an
        // in-memory snapshot to `SessionStore(restoring:)` directly. The
        // production restore path goes through the on-disk JSON in
        // Application Support — an in-memory test would still pass if a
        // future refactor dropped or renamed the `agentState` key in
        // `TerminalSession.encode(to:)`.
        let waitingSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .waiting
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [waitingSession])],
            selectedSessionID: waitingSession.id
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let store = SessionStore(restoring: decoded)

        XCTAssertEqual(store.selectedSession?.agentState, .waiting)
    }

    @MainActor
    func testRestoringWaitingSessionPreservesLivePromptDropsUnreadNoise() throws {
        let waitingSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            attentionReason: .permissionPrompt,
            unreadNotificationCount: 3
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [waitingSession])],
            selectedSessionID: waitingSession.id
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let store = SessionStore(restoring: decoded)

        // R5: a live permission prompt survives relaunch (restores badged); the
        // unread COUNT is still dropped as runtime noise.
        XCTAssertEqual(store.selectedSession?.agentExecutionState, .waiting)
        XCTAssertEqual(store.selectedSession?.attentionReason, .permissionPrompt)
        XCTAssertEqual(store.selectedSession?.agentState, .needsAttention)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 0)
    }

    // MARK: - Pane-color tolerance through the SessionSnapshot decode path

    /// A pane carrying an unknown color buried inside a nested split MUST NOT
    /// quarantine the snapshot. The snapshot decodes successfully, siblings keep
    /// their colors, and only the bad pane's color decodes to nil.
    ///
    /// Uses the `SessionSnapshot` decode level (not SessionPersistence, which is
    /// in the app target and unreachable from AwesoMuxCoreTests). This level is
    /// correct because `decodeTolerantColor` fires inside `TerminalPane.init(from:)`
    /// which is called by the snapshot's group/session decode chain — it is the
    /// same code path the persistence service invokes.
    func testNestedSplitWithUnknownPaneColorDecodesWithoutQuarantine() throws {
        // Build a snapshot in memory with a nested split: root → (left, inner → (innerLeft, innerRight))
        let leftPane = TerminalPane(title: "left", workingDirectory: "/l")
        var innerRightPane = TerminalPane(title: "innerRight", workingDirectory: "/ir")
        innerRightPane.color = .palette(.teal)  // known good color — will survive
        let innerLeftPane = TerminalPane(title: "innerLeft", workingDirectory: "/il")

        let innerSplit = TerminalSplit(
            orientation: .horizontal,
            first: .pane(innerLeftPane),
            second: .pane(innerRightPane),
            firstFraction: 0.5
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(leftPane),
            second: .split(innerSplit),
            firstFraction: 0.5
        ))
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: layout,
            activePaneID: leftPane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [session])],
            selectedSessionID: session.id
        )

        // Encode to JSON, then surgically replace innerLeftPane's color entry
        // with an unknown future color ("kind":"theme") to simulate a snapshot
        // written by a newer build.
        var jsonObj = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(snapshot)
            ) as? [String: Any]
        )
        // Walk: groups[0].sessions[0].layout → split._0 → second → split._0 → first → pane._0
        // The synthesized enum Codable nests associated values under "_0".
        var groups = try XCTUnwrap(jsonObj["groups"] as? [[String: Any]])
        var sessions = try XCTUnwrap(groups[0]["sessions"] as? [[String: Any]])
        var sessionObj = try XCTUnwrap(sessions[0])
        var rootLayout = try XCTUnwrap(sessionObj["layout"] as? [String: Any])
        var rootSplit = try XCTUnwrap((rootLayout["split"] as? [String: Any])?["_0"] as? [String: Any])
        var secondBranch = try XCTUnwrap(rootSplit["second"] as? [String: Any])
        var innerSplitObj = try XCTUnwrap((secondBranch["split"] as? [String: Any])?["_0"] as? [String: Any])
        var firstBranch = try XCTUnwrap(innerSplitObj["first"] as? [String: Any])
        var paneObj = try XCTUnwrap((firstBranch["pane"] as? [String: Any])?["_0"] as? [String: Any])
        // Inject the bad color directly onto innerLeftPane's JSON object.
        paneObj["color"] = ["kind": "theme", "name": "ultraviolet"]

        // Reconstruct the JSON tree bottom-up.
        var firstBranchPane = firstBranch["pane"] as! [String: Any]
        firstBranchPane["_0"] = paneObj
        firstBranch["pane"] = firstBranchPane
        innerSplitObj["first"] = firstBranch
        var secondBranchSplit = secondBranch["split"] as! [String: Any]
        secondBranchSplit["_0"] = innerSplitObj
        secondBranch["split"] = secondBranchSplit
        rootSplit["second"] = secondBranch
        var rootLayoutSplit = rootLayout["split"] as! [String: Any]
        rootLayoutSplit["_0"] = rootSplit
        rootLayout["split"] = rootLayoutSplit
        sessionObj["layout"] = rootLayout
        sessions[0] = sessionObj
        groups[0]["sessions"] = sessions
        jsonObj["groups"] = groups

        let modifiedData = try JSONSerialization.data(withJSONObject: jsonObj)

        // Decode must succeed without throwing (no quarantine).
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: modifiedData)
        let decodedSession = try XCTUnwrap(decoded.groups.first?.sessions.first)

        // Siblings with valid colors survive intact.
        let restoredInnerRight = try XCTUnwrap(decodedSession.layout.pane(id: innerRightPane.id))
        XCTAssertEqual(restoredInnerRight.color, .palette(.teal), "sibling pane color must survive")

        // The pane with the bad color decodes to nil — not a crash or quarantine.
        let restoredInnerLeft = try XCTUnwrap(decodedSession.layout.pane(id: innerLeftPane.id))
        XCTAssertNil(restoredInnerLeft.color, "pane with unknown color must decode to nil, not quarantine")

        // The other pane (leftPane) is also unaffected.
        let restoredLeft = try XCTUnwrap(decodedSession.layout.pane(id: leftPane.id))
        XCTAssertNil(restoredLeft.color)
    }
}
