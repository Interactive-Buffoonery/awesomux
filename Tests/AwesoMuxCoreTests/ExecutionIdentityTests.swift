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

  @Test("local and SSH plans round trip")
  func planRoundTrip() throws {
    let plans: [PaneExecutionPlan] = [
      .local,
      .ssh(SSHExecution(target: RemoteTarget(user: "alice", host: "buildbox"))),
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
        location: .remote(RemoteTarget(user: "alice", host: "dev-a")),
        path: path
      ),
      ResourceIdentity(
        location: .remote(RemoteTarget(user: "alice", host: "dev-b")),
        path: path
      ),
    ]

    #expect(identities.count == 3)
    let encoded = try JSONEncoder().encode(identities)
    #expect(try JSONDecoder().decode(Set<ResourceIdentity>.self, from: encoded) == identities)
  }

  @Test("capabilities follow declared execution location")
  func capabilityResolution() {
    let target = RemoteTarget(user: "alice", host: "buildbox")
    let local = ExecutionContext(plan: .local)
    let remote = ExecutionContext(plan: .ssh(SSHExecution(target: target)))

    #expect(local.capability(.revealInFinder) == .allowed)
    #expect(local.capability(.readRemoteResource) == .denied(.requiresRemoteExecution))
    #expect(remote.capability(.revealInFinder) == .denied(.requiresLocalExecution))
    #expect(remote.capability(.readRemoteResource) == .allowed)
  }

  @MainActor
  @Test(
    "legacy panes inherit their group's location without a schema bump",
    arguments: [
      nil,
      RemoteTarget(user: "alice", host: "buildbox"),
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

    let decoded = try JSONDecoder().decode(
      SessionSnapshot.self,
      from: legacyData
    )
    let restored = SessionStore(restoring: decoded).selectedSession?.activePane
    let expected =
      groupRemote.map { PaneExecutionPlan.ssh(SSHExecution(target: $0)) }
      ?? .local

    #expect(decoded.schemaVersion == SessionSnapshot.currentSchemaVersion)
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
      try JSONDecoder().decode(SessionSnapshot.self, from: activeData)
    }

    var rowJSON = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(snapshot)
      ) as? [String: Any])
    rowJSON["recentlyClosed"] = [["layout": ["pane": ["executionPlan": malformedPlan]]]]
    let decoded = try JSONDecoder().decode(
      SessionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: rowJSON)
    )
    #expect(decoded.groups.count == 1)
    #expect(decoded.recentlyClosed.isEmpty)
  }
}
