import Foundation
import Testing
@testable import AwesoMuxCore

/// INT-811 guards that formalizing the typed pane model changed NO encoded form:
/// a v7 snapshot with a terminal + a document group (carrying a terminal
/// association and remote provenance) round-trips losslessly, and durable
/// identity survives even though `TerminalPane`/`DocumentPane` `Equatable`
/// deliberately excludes some durable/runtime fields. The lossless contract is
/// checked on the DURABLE fields explicitly, not via `==`.
@Suite struct TypedPaneSnapshotRoundTripTests {
    private func decodeVersioned(_ data: Data, version: Int) throws -> SessionSnapshot {
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = version
        return try decoder.decode(SessionSnapshot.self, from: data)
    }

    private func fixtureSnapshot() -> (SessionSnapshot, terminal: TerminalPane, tab: DocumentPane) {
        let terminal = TerminalPane(
            id: UUID(),
            terminalSessionID: .generate(),
            title: "build",
            isTitleUserEdited: true,
            workingDirectory: "/work",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(user: "ed", host: "box")!))
        )
        let remoteIdentity = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "me@example.com")!),
            path: ResourcePath(rawValue: "/home/me/plan.md")
        )
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/cache/plan.md"),
            title: "plan.md",
            associatedTerminalPaneID: terminal.id,
            remoteResourceIdentity: remoteIdentity
        )
        let group = DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(group),
                firstFraction: 0.6
            ))
        let session = TerminalSession(
            title: "build",
            workingDirectory: "/work",
            layout: layout,
            activePaneID: terminal.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "One", sessions: [session])],
            selectedSessionID: session.id
        )
        return (snapshot, terminal, tab)
    }

    @Test func snapshotEncodesAtCurrentSchemaVersion() throws {
        let (snapshot, _, _) = fixtureSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == SessionSnapshot.currentSchemaVersion)
    }

    @Test func terminalIdentityAndExecutionPlanSurviveRoundTrip() throws {
        let (snapshot, terminal, _) = fixtureSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try decodeVersioned(data, version: SessionSnapshot.currentSchemaVersion)

        let restored = try #require(decoded.groups.first?.sessions.first)
        let restoredTerminal = try #require(restored.layout.pane(id: terminal.id))
        // Durable identity checked explicitly — Equatable excludes terminalSessionID.
        #expect(restoredTerminal.id == terminal.id)
        #expect(restoredTerminal.terminalSessionID == terminal.terminalSessionID)
        #expect(restoredTerminal.executionPlan == terminal.executionPlan)
        #expect(restoredTerminal.executionPlan.remoteTarget?.host == "box")
        #expect(restoredTerminal.title == "build")
        #expect(restoredTerminal.isTitleUserEdited)
    }

    @Test func documentAssociationAndRemoteProvenanceSurviveRoundTrip() throws {
        let (snapshot, terminal, tab) = fixtureSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try decodeVersioned(data, version: SessionSnapshot.currentSchemaVersion)

        let restored = try #require(decoded.groups.first?.sessions.first)
        let group = try #require(restored.layout.firstDocumentGroup)
        let restoredTab = try #require(group.tab(id: tab.id))
        #expect(restoredTab.associatedTerminalPaneID == terminal.id)
        // Remote provenance survives as typed identity, never degrading to local.
        #expect(restoredTab.isReadOnlySnapshot)
        #expect(restoredTab.remoteResourceIdentity?.remoteTarget?.host == "example.com")
    }

    @Test func malformedRemotePlanFailsLoudNeverDegradesToLocal() throws {
        // INT-775 contract preserved: a plan tagged ssh but missing its target
        // must throw, not silently decode as a local pane.
        let json = """
            {"kind":"ssh"}
            """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneExecutionPlan.self, from: Data(json.utf8))
        }
    }
}
