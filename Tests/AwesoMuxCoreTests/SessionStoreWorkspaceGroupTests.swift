import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Workspace Groups")
struct SessionStoreWorkspaceGroupTests {

    @Test("addLocalSession fails closed for a missing group")
    func addLocalSessionRejectsMissingGroup() {
        let original = SessionGroup(name: "work", sessions: [])
        let store = SessionStore(groups: [original])
        let initialGroups = store.groups

        let id = store.addLocalSession(
            title: "feature",
            workingDirectory: "/tmp/feature",
            toGroupID: UUID()
        )

        #expect(id == nil)
        #expect(store.groups == initialGroups)
    }

    @Test("addLocalSession never inherits a group's remote default")
    func addLocalSessionInRemoteGroupStaysLocal() throws {
        let remote = try #require(RemoteTarget(parsing: "dev@example.com"))
        let group = SessionGroup(name: "remote", remote: remote, sessions: [])
        let store = SessionStore(groups: [group])

        let id = store.addLocalSession(
            title: nil,
            workingDirectory: "/tmp/local-worktree",
            toGroupID: group.id
        )

        let session = try #require(store.groups[0].sessions.first { $0.id == id })
        #expect(session.activePane?.executionPlan == .local)
    }

    @Test("managed SSH workspace keeps pane identity without changing group default")
    func addSSHSessionKeepsPaneOwnedIdentity() throws {
        let local = TerminalSession(title: "shell 1", workingDirectory: "~")
        let group = SessionGroup(name: "Current Group", sessions: [local])
        let store = SessionStore(groups: [group], selectedSessionID: local.id)
        let target = try #require(RemoteTarget(parsing: "my-server"))
        let sessionID = try #require(store.addSSHSession(target: target, toGroupID: group.id))

        #expect(store.groups[0].remote == nil)
        let plan = store.session(id: sessionID)?.activePane?.executionPlan
        #expect(plan == .ssh(SSHExecution(target: target)))
        #expect(plan?.remoteOwnedExecution == nil)
        store.moveSession(id: sessionID, toGroupID: group.id, atIndex: 0)
        let data = try JSONEncoder().encode(store.snapshot())
        let restored = SessionStore(restoring: try SessionSnapshot.decode(from: data))
        #expect(restored.session(id: sessionID)?.activePane?.executionPlan == .ssh(SSHExecution(target: target)))
        #expect(restored.groups[0].remote == nil)
    }

    @Test("a declared session name makes the new SSH workspace remote-owned")
    func addSSHSessionDeclaresRemoteOwnedSession() throws {
        let group = SessionGroup(name: "Work", sessions: [])
        let store = SessionStore(groups: [group])
        let target = try #require(RemoteTarget(parsing: "my-server"))
        let sessionName = try #require(RemoteSessionName(rawValue: "my-session"))
        let sessionID = try #require(
            store.addSSHSession(
                target: target,
                toGroupID: group.id,
                sessionName: sessionName
            ))

        let execution = try #require(
            store.session(id: sessionID)?.activePane?.executionPlan.remoteOwnedExecution)
        #expect(execution.target == target)
        #expect(execution.sessionName == sessionName)
    }

    @Test("managed SSH conversion replaces the active pane in place")
    func managedSSHConversionReplacesActivePaneInPlace() throws {
        let sibling = TerminalPane(title: "local", workingDirectory: "~", executionPlan: .local)
        let converting = TerminalPane(title: "ssh", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(sibling),
                    second: .pane(converting)
                )),
            activePaneID: converting.id
        )
        let group = SessionGroup(name: "Work", sessions: [session])
        let store = SessionStore(groups: [group], selectedSessionID: session.id)
        let target = try #require(RemoteTarget(parsing: "my-server"))

        #expect(
            store.convertPaneToManagedSSH(
                sessionID: session.id,
                paneID: converting.id,
                target: target
            ) == converting.id
        )
        #expect(store.groups[0].sessions.map(\.id) == [session.id])
        #expect(store.groups[0].remote == nil)
        #expect(store.session(id: session.id)?.layout.pane(id: sibling.id) == sibling)
        #expect(store.session(id: session.id)?.activePane?.id != converting.id)
        #expect(store.session(id: session.id)?.activePane?.executionPlan == .ssh(SSHExecution(target: target)))
    }

    @Test("a declared session name makes the converted pane remote-owned")
    func managedSSHConversionDeclaresRemoteOwnedSession() throws {
        let converting = TerminalPane(title: "ssh", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .pane(converting),
            activePaneID: converting.id
        )
        let group = SessionGroup(name: "Work", sessions: [session])
        let store = SessionStore(groups: [group], selectedSessionID: session.id)
        let target = try #require(RemoteTarget(parsing: "my-server"))
        let sessionName = try #require(RemoteSessionName(rawValue: "my-session"))

        #expect(
            store.convertPaneToManagedSSH(
                sessionID: session.id,
                paneID: converting.id,
                target: target,
                sessionName: sessionName
            ) == converting.id
        )

        let execution = try #require(
            store.session(id: session.id)?.activePane?.executionPlan.remoteOwnedExecution)
        #expect(execution.target == target)
        #expect(execution.sessionName == sessionName)
    }

    @Test("remoteTarget finds the active pane's declared target")
    func remoteTargetLookupFindsActivePanePlan() {
        let target = RemoteTarget(user: "ed", host: "box")!
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let group = SessionGroup(
            name: "box",
            remote: target,
            sessions: [session]
        )
        let store = SessionStore(groups: [group], selectedSessionID: session.id)

        #expect(store.remoteTarget(forSessionID: session.id) == target)
    }

    @Test("an explicit local pane is not retargeted by its remote group")
    func remoteGroupDoesNotOverrideExplicitLocalPane() {
        let target = RemoteTarget(user: "ed", host: "box")!
        let session = TerminalSession(
            title: "local utility",
            workingDirectory: "~"
        )
        let group = SessionGroup(name: "box", remote: target, sessions: [session])
        let store = SessionStore(groups: [group], selectedSessionID: session.id)

        #expect(store.remoteTarget(forSessionID: session.id) == nil)
    }

    @Test("a workspace added to a remote group after a persistence round-trip attaches remote")
    func addSessionAfterPersistenceRoundTripResolvesRemoteTarget() throws {
        let store = SessionStore(groups: [])
        let target = RemoteTarget(user: "ed", host: "box")!
        _ = store.createRemoteWorkspaceGroup(named: "box", target: target)

        // Full persistence boundary — encode/decode the snapshot, not just the
        // reducer: the INT-767 drop happened between an intact Codable layer
        // and the in-memory rebuild.
        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try SessionSnapshot.decode(from: data)

        let restored = SessionStore(restoring: decoded)
        #expect(restored.groups.first?.remote == target)
        let addedID = restored.addSession(groupName: "box")
        #expect(restored.remoteTarget(forSessionID: addedID) == target)

        // replaceState shares the reducer but is its own public restore entry
        // point — hold it to the same contract.
        let replaced = SessionStore(groups: [])
        replaced.replaceState(restoring: decoded)
        #expect(replaced.groups.first?.remote == target)
        #expect(
            replaced.remoteTarget(forSessionID: replaced.addSession(groupName: "box")) == target
        )
    }

    @Test(
        "add and rename enforce the same name policy",
        arguments: [
            (false, " \n\t ", ["scratch"], Optional<[String]>.none),
            (false, "SCRATCH", ["scratch"], nil),
            (false, "scratch", ["scratch\u{200B}"], nil),
            (false, "scratch", ["scratch\u{200D}"], nil),
            (false, " \u{202E}scratch\u{0007} ", [], ["scratch"]),
            (false, "\u{0421}l\u{0430}ud\u{0435}", [], nil),
            (true, " \n\t ", ["awesoMux"], nil),
            (true, "SCRATCH", ["awesoMux", "scratch"], nil),
            (true, "scratch", ["awesoMux", "scratch\u{200B}"], nil),
            (true, "scratch", ["scratch\u{200C}", "scratch\u{200D}"], nil),
            (true, " \u{202E}scratch\u{0007} ", ["awesoMux"], ["scratch"]),
            (true, "\u{0421}l\u{0430}ud\u{0435}", ["scratch"], nil),
        ])
    func namePolicy(rename: Bool, input: String, existing: [String], expected: [String]?) {
        let groups = existing.map { SessionGroup(name: $0, sessions: [TerminalSession(title: "shell", workingDirectory: "~")]) }
        let store = SessionStore(groups: groups)
        let original = store.groups
        let accepted: Bool
        if rename {
            accepted = store.renameGroup(id: groups[0].id, to: input)
        } else {
            accepted = store.addWorkspaceGroup(named: input) != nil
        }
        #expect(accepted == (expected != nil))
        #expect(store.groups.map(\.name) == (expected ?? existing))
        if expected == nil {
            #expect(store.groups == original)
        }
    }

    @Test(
        "session routing never invents phantom groups",
        arguments: [
            (["Scratch"], ["scratch"], "Scratch"),
            (["scratch\u{200B}"], ["scratch"], "scratch\u{200B}"),
            ([], ["\u{202E}", "\u{202E}"], SessionStore.canonicalDefaultGroupName),
            ([], ["\u{202E}", "\u{200B}\u{FEFF}", "\u{0301}"], SessionStore.canonicalDefaultGroupName),
            ([], ["\u{0421}l\u{0430}ud\u{0435}"], SessionStore.canonicalDefaultGroupName),
        ])
    func sessionRouting(existing: [String], inputs: [String], expected: String) {
        let original = existing.map { SessionGroup(name: $0, sessions: [TerminalSession(title: "shell 1", workingDirectory: "~")]) }
        let store = SessionStore(groups: original)
        let ids = inputs.map { store.addSession(groupName: $0) }
        #expect(store.groups.map(\.name) == [expected])
        #expect(store.groups[0].sessions.map(\.id) == original.flatMap(\.sessions).map(\.id) + ids)
    }

    @Test(
        "restore merges or quarantines names without losing their sessions",
        arguments: [
            ([" \u{202E}scratch\u{0007}\u{200B} "], ["scratch"]),
            (["\u{202E}\u{200B}"], []),
            (["scratch", "scratch\u{200B}"], ["scratch"]),
            (["scratch\u{200C}", "scratch\u{200D}"], ["scratch"]),
            (["\u{0421}l\u{0430}ud\u{0435}"], [SessionStore.canonicalDefaultGroupName]),
            (["\u{0421}l\u{0430}ud\u{0435}", "\u{0391}\u{0430}"], [SessionStore.canonicalDefaultGroupName]),
        ])
    func restoredNames(names: [String], expected: [String]) {
        let sessions = names.indices.map {
            TerminalSession(title: "shell \($0 + 1)", workingDirectory: "~", agentKind: .shell, agentState: .running)
        }
        let groups = zip(names, sessions).map { SessionGroup(name: $0, sessions: [$1]) }
        let store = SessionStore(restoring: SessionSnapshot(groups: groups, selectedSessionID: sessions[0].id))
        #expect(store.groups.map(\.name) == expected)
        #expect(store.groups.flatMap(\.sessions).map(\.id) == (expected.isEmpty ? [] : sessions.map(\.id)))
        #expect(store.selectedSessionID == (expected.isEmpty ? nil : sessions[0].id))
    }
}
