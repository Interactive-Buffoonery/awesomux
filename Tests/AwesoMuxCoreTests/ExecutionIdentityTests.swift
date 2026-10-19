import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("Execution identity")
struct ExecutionIdentityTests {
    private func replacingExecutionPlans(in value: Any, with replacement: Any?) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["executionPlan"] != nil {
                dictionary["executionPlan"] = replacement
            }
            return dictionary.mapValues { replacingExecutionPlans(in: $0, with: replacement) }
        }
        if let array = value as? [Any] {
            return array.map { replacingExecutionPlans(in: $0, with: replacement) }
        }
        return value
    }

    private func removingLayouts(in value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary.removeValue(forKey: "layout")
            return dictionary.mapValues(removingLayouts(in:))
        }
        if let array = value as? [Any] {
            return array.map(removingLayouts(in:))
        }
        return value
    }

    @Test(
        "malformed remote plans fail decoding",
        arguments: [
            #"{"kind":"ssh","persistenceOwner":"localAmx"}"#,
            #"{"kind":"ssh","target":{"user":"alice","host":""},"persistenceOwner":"localAmx"}"#,
            #"{"kind":"local","target":{"user":"alice","host":"buildbox"}}"#,
            #"{"kind":"future"}"#,
            // A local-amx plan owns no remote session identity.
            #"{"kind":"ssh","target":{"user":"a","host":"b"},"persistenceOwner":"localAmx","sessionName":"build"}"#,
            // A remote-owned plan must name its session.
            #"{"kind":"ssh","target":{"user":"a","host":"b"},"persistenceOwner":"remoteZmx"}"#,
            #"{"kind":"ssh","target":{"user":"a","host":"b"},"persistenceOwner":"remoteZmx","sessionName":"bad name"}"#,
            // Local plans stay free of every SSH field.
            #"{"kind":"local","sessionName":"build"}"#,
        ])
    func malformedPlansFail(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneExecutionPlan.self, from: Data(json.utf8))
        }
    }

    /// The key is gone from the model (#235 replaced it with far-side
    /// discovery), so a snapshot written before that must still open — the
    /// stale path is ignored, not a decode failure.
    @Test("a plan carrying the retired remote executable path still decodes")
    func retiredExecutablePathKeyIsIgnored() throws {
        let json =
            #"{"kind":"ssh","target":{"user":"alice","host":"buildbox"},"persistenceOwner":"remoteZmx","sessionName":"build","remoteExecutablePath":"/usr/local/bin/zmx"}"#
        let plan = try JSONDecoder().decode(PaneExecutionPlan.self, from: Data(json.utf8))

        guard case .ssh(let execution) = plan else {
            Issue.record("expected an ssh plan")
            return
        }
        #expect(execution.persistenceOwner == .remoteZmx)
        #expect(execution.sessionName?.rawValue == "build")
    }

    @MainActor
    @Test(arguments: [
        (nil as RemoteTarget?, "missing", "/srv/app", SessionSnapshot.currentSchemaVersion),
        (RemoteTarget(user: "alice", host: "buildbox"), "missing", "/srv/app", SessionSnapshot.currentSchemaVersion),
        (RemoteTarget(user: "alice", host: "prod-host"), "noLayout", "~", 1),
        (RemoteTarget(user: "alice", host: "prod-host"), "null", "~", SessionSnapshot.currentSchemaVersion),
    ])
    func migratesLegacyLocation(groupRemote: RemoteTarget?, shape: String, directory: String, version: Int) throws {
        let pane = TerminalPane(title: "legacy", workingDirectory: directory, executionPlan: .local)
        let session = TerminalSession(
            title: "legacy", workingDirectory: directory,
            layout: .pane(pane), activePaneID: pane.id)
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: shape == "missing" ? "work" : "prod", remote: groupRemote, sessions: [session])],
            selectedSessionID: session.id)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let migrated: Any
        switch shape {
        case "noLayout": migrated = removingLayouts(in: encoded)
        case "null": migrated = replacingExecutionPlans(in: encoded, with: NSNull())
        default: migrated = replacingExecutionPlans(in: encoded, with: nil)
        }
        var json = try #require(migrated as? [String: Any])
        json["schemaVersion"] = version
        let decoded = try SessionSnapshot.decode(from: JSONSerialization.data(withJSONObject: json))
        let restored = SessionStore(restoring: decoded).selectedSession?.activePane
        let expected = groupRemote.map { PaneExecutionPlan.ssh(SSHExecution(target: $0)) } ?? .local
        #expect(decoded.schemaVersion == version)
        #expect(restored?.executionPlan == expected)
    }

    @Test("malformed active pane plan fails while a malformed recently-closed row is dropped")
    func malformedPersistenceScopesFailure() throws {
        let malformedPlan = [
            "kind": "ssh",
            "persistenceOwner": "localAmx",
        ]
        let pane = TerminalPane(title: "active", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "active",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let activeJSON = replacingExecutionPlans(in: encoded, with: malformedPlan)
        let activeData = try JSONSerialization.data(withJSONObject: activeJSON)

        #expect(throws: (any Error).self) {
            try SessionSnapshot.decode(from: activeData)
        }

        var rowJSON = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot)
            ) as? [String: Any])
        rowJSON["recentlyClosed"] = [["layout": ["pane": ["executionPlan": malformedPlan]]]]
        let decoded = try SessionSnapshot.decode(
            from: JSONSerialization.data(withJSONObject: rowJSON)
        )
        #expect(decoded.groups.count == 1)
        #expect(decoded.recentlyClosed.isEmpty)
    }
}
