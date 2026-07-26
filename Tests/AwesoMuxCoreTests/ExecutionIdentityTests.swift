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

    @Test("local and SSH plans round trip")
    func planRoundTrip() throws {
        let plans: [PaneExecutionPlan] = [
            .local,
            .ssh(SSHExecution(target: RemoteTarget(user: "alice", host: "buildbox")!)),
        ]

        for plan in plans {
            let data = try JSONEncoder().encode(plan)
            #expect(try JSONDecoder().decode(PaneExecutionPlan.self, from: data) == plan)
        }
    }

    @Test(
        "malformed remote plans fail decoding",
        arguments: [
            #"{"kind":"ssh","persistenceOwner":"localAmx"}"#,
            #"{"kind":"ssh","target":{"user":"alice","host":""},"persistenceOwner":"localAmx"}"#,
            #"{"kind":"local","target":{"user":"alice","host":"buildbox"}}"#,
            #"{"kind":"future"}"#,
        ])
    func malformedPlansFail(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneExecutionPlan.self, from: Data(json.utf8))
        }
    }

    @Test("same path differs across execution locations")
    func hostAwareResourceIdentity() throws {
        let path = ResourcePath(rawValue: "/repo/plan.md")
        let identities: Set<ResourceIdentity> = [
            ResourceIdentity(location: .local, path: path),
            ResourceIdentity(
                location: .remote(RemoteTarget(user: "alice", host: "dev-a")!),
                path: path
            ),
            ResourceIdentity(
                location: .remote(RemoteTarget(user: "alice", host: "dev-b")!),
                path: path
            ),
        ]

        #expect(identities.count == 3)
        let encoded = try JSONEncoder().encode(identities)
        #expect(try JSONDecoder().decode(Set<ResourceIdentity>.self, from: encoded) == identities)
    }

    @Test("capabilities follow declared execution location")
    func capabilityResolution() {
        let target = RemoteTarget(user: "alice", host: "buildbox")!
        let local = ExecutionContext(plan: .local)
        let remote = ExecutionContext(plan: .ssh(SSHExecution(target: target)))

        #expect(local.capability(.revealInFinder) == .allowed)
        #expect(remote.capability(.revealInFinder) == .denied(.requiresLocalExecution))
        #expect(local.capability(.copyLocalPath) == .allowed)
        #expect(remote.capability(.copyLocalPath) == .denied(.requiresLocalExecution))
        #expect(local.capability(.stageLocalDocumentPath) == .allowed)
        #expect(remote.capability(.stageLocalDocumentPath) == .denied(.requiresLocalExecution))
    }

    @MainActor
    @Test(
        "legacy panes inherit their group's location without a schema bump",
        arguments: [
            nil,
            RemoteTarget(user: "alice", host: "buildbox")!,
        ])
    func legacyPaneMigration(groupRemote: RemoteTarget?) throws {
        let pane = TerminalPane(
            title: "legacy",
            workingDirectory: "/srv/app",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "legacy",
            workingDirectory: "/srv/app",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "work", remote: groupRemote, sessions: [session])],
            selectedSessionID: session.id
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let legacyJSON = replacingExecutionPlans(in: encoded, with: nil)
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyJSON
        )

        let decoded = try SessionSnapshot.decode(from: legacyData)
        let restored = SessionStore(restoring: decoded).selectedSession?.activePane
        let expected =
            groupRemote.map { PaneExecutionPlan.ssh(SSHExecution(target: $0)) }
            ?? .local

        #expect(decoded.schemaVersion == SessionSnapshot.currentSchemaVersion)
        #expect(restored?.executionPlan == expected)
    }

    @MainActor
    @Test("a true v1 remote session without a layout inherits its group target")
    func trueV1SessionWithoutLayoutInheritsRemoteTarget() throws {
        let target = RemoteTarget(user: "alice", host: "prod-host")!
        let session = TerminalSession(title: "legacy", workingDirectory: "~")
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "prod", remote: target, sessions: [session])],
            selectedSessionID: session.id
        )
        var json = try #require(
            removingLayouts(
                in: JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            ) as? [String: Any]
        )
        json["schemaVersion"] = 1

        let decoded = try SessionSnapshot.decode(
            from: JSONSerialization.data(withJSONObject: json)
        )
        let restored = SessionStore(restoring: decoded).selectedSession?.activePane

        #expect(restored?.executionPlan == .ssh(SSHExecution(target: target)))
    }

    @MainActor
    @Test("a null pane plan inherits its legacy remote group target")
    func nullPanePlanInheritsRemoteTarget() throws {
        let target = RemoteTarget(user: "alice", host: "prod-host")!
        let pane = TerminalPane(title: "legacy", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "legacy",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "prod", remote: target, sessions: [session])],
            selectedSessionID: session.id
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let data = try JSONSerialization.data(
            withJSONObject: replacingExecutionPlans(in: encoded, with: NSNull())
        )

        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionStore(restoring: decoded).selectedSession?.activePane

        #expect(restored?.executionPlan == .ssh(SSHExecution(target: target)))
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
