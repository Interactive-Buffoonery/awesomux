import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Workspace Groups")
struct SessionStoreWorkspaceGroupTests {
    @Test("addWorkspaceGroup creates a starter workspace and selects it")
    func createsStarterWorkspaceAndSelectsIt() {
        let existingSession = TerminalSession(
            title: "shell 1",
            workingDirectory: "/Users/example/Development/awesomux",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [existingSession])
        ])

        let newSessionID = store.addWorkspaceGroup(named: "scratch")

        #expect(store.groups.map(\.name) == ["awesoMux", "scratch"])
        #expect(store.groups[1].sessions.map(\.id) == [newSessionID])
        #expect(store.selectedSessionID == newSessionID)
        #expect(store.selectedSession?.title == "shell 2")
        #expect(
            store.selectedSession?.workingDirectory
                == "/Users/example/Development/awesomux"
        )
        #expect(store.selectedSession?.agentState == .idle)
    }

    @Test("addWorkspaceGroup sanitises bidi and control characters")
    func sanitisesName() {
        let store = SessionStore(groups: [])

        _ = store.addWorkspaceGroup(named: " \u{202E}scratch\u{0007} ")

        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("addWorkspaceGroup rejects blank or case-insensitive duplicate names")
    func rejectsBlankOrDuplicateNames() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "scratch",
                sessions: [
                    TerminalSession(
                        title: "shell 1",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        #expect(store.addWorkspaceGroup(named: " \n\t ") == nil)
        #expect(store.addWorkspaceGroup(named: "SCRATCH") == nil)
        #expect(store.groups.count == 1)
    }

    @Test("addWorkspaceGroup rejects a duplicate that only matches after sanitisation")
    func rejectsDuplicateAfterSanitization() {
        let pollutedSession = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        // The stored name has a trailing zero-width space — without
        // sanitising both sides of the comparison, a fresh `scratch`
        // would sneak past the dedup check.
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch\u{200B}", sessions: [pollutedSession])
        ])

        #expect(store.addWorkspaceGroup(named: "scratch") == nil)
        #expect(store.groups.count == 1)
    }

    @Test("addWorkspaceGroup rejects a duplicate that only differs by a joiner")
    func rejectsDuplicateAfterJoinerSanitization() {
        let pollutedSession = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch\u{200D}", sessions: [pollutedSession])
        ])

        #expect(store.addWorkspaceGroup(named: "scratch") == nil)
        #expect(store.groups.count == 1)
    }

    @Test("renameGroup updates the visible group name and preserves sessions")
    func renameGroupUpdatesNameAndPreservesSessions() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "awesoMux", sessions: [session])
        let store = SessionStore(groups: [group], selectedSessionID: session.id)

        #expect(store.renameGroup(id: group.id, to: "  Scratch  ") == true)

        #expect(store.groups.map(\.name) == ["Scratch"])
        #expect(store.groups[0].id == group.id)
        #expect(store.groups[0].sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
    }

    @Test("renameGroup sanitises bidi and control characters")
    func renameGroupSanitisesName() {
        let group = SessionGroup(name: "awesoMux", sessions: [])
        let store = SessionStore(groups: [group])

        #expect(store.renameGroup(id: group.id, to: " \u{202E}scratch\u{0007} ") == true)

        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("renameGroup rejects blank or case-insensitive duplicate names")
    func renameGroupRejectsBlankOrDuplicateNames() {
        let first = SessionGroup(name: "awesoMux", sessions: [])
        let second = SessionGroup(name: "Scratch", sessions: [])
        let store = SessionStore(groups: [first, second])

        #expect(store.renameGroup(id: first.id, to: " \n\t ") == false)
        #expect(store.renameGroup(id: first.id, to: "scratch") == false)

        #expect(store.groups.map(\.name) == ["awesoMux", "Scratch"])
    }

    @Test("renameGroup rejects a duplicate that only differs by a joiner")
    func renameGroupRejectsJoinerOnlyDuplicateNames() {
        let first = SessionGroup(name: "scratch\u{200C}", sessions: [])
        let second = SessionGroup(name: "scratch\u{200D}", sessions: [])
        let store = SessionStore(groups: [first, second])

        #expect(store.renameGroup(id: first.id, to: "scratch") == false)

        #expect(store.groups.map(\.name) == ["scratch\u{200C}", "scratch\u{200D}"])
    }

    @Test("renameGroup is a successful no-op when the sanitised name is unchanged")
    func renameGroupNoOpReturnsTrue() {
        let group = SessionGroup(name: "scratch", sessions: [])
        let store = SessionStore(groups: [group])

        #expect(store.renameGroup(id: group.id, to: "  scratch  ") == true)
        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("renameGroup returns false for an unknown group id")
    func renameGroupRejectsUnknownID() {
        let group = SessionGroup(name: "scratch", sessions: [])
        let store = SessionStore(groups: [group])

        #expect(store.renameGroup(id: UUID(), to: "anything") == false)
        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("addSession finds an existing group case-insensitively")
    func addSessionFindsExistingGroupCaseInsensitively() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Scratch",
                sessions: [
                    TerminalSession(
                        title: "shell 1",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        _ = store.addSession(groupName: "scratch")

        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == "Scratch")
        #expect(store.groups[0].sessions.count == 2)
    }

    @Test("addSession appends to a preserved empty group")
    func addSessionAppendsToPreservedEmptyGroup() {
        let store = SessionStore(groups: [
            SessionGroup(name: "Scratch", sessions: [])
        ])

        let sessionID = store.addSession(groupName: "scratch")

        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == "Scratch")
        #expect(store.groups[0].sessions.map(\.id) == [sessionID])
        #expect(store.selectedSessionID == sessionID)
    }

    @Test("addSession dedups repeat calls whose names sanitise to empty")
    func addSessionDedupsEmptyAfterSanitise() {
        let store = SessionStore(groups: [])

        // Both inputs strip to empty, so the lookup key falls back to the
        // canonical default group for each — they collapse into one group
        // rather than minting a phantom per call.
        _ = store.addSession(groupName: "\u{202E}")
        _ = store.addSession(groupName: "\u{202E}")

        #expect(store.groups.count == 1)
        #expect(store.groups[0].sessions.count == 2)
    }

    @Test("addSession routes distinct all-invisible names to one canonical group")
    func addSessionCollapsesDistinctEmptiesToCanonical() {
        let store = SessionStore(groups: [])

        // Different all-invisible inputs all sanitise to empty and therefore
        // share the canonical-default lookup key — they must merge, not split
        // into one phantom group each. (Pins the canonical fallback, which a
        // raw-input fallback would have failed.)
        _ = store.addSession(groupName: "\u{202E}")       // RLO
        _ = store.addSession(groupName: "\u{200B}\u{FEFF}") // zero-width + BOM
        _ = store.addSession(groupName: "\u{0301}")        // combining mark only

        #expect(store.groups.count == 1)
        #expect(store.groups[0].sessions.count == 3)
    }

    @Test("addSession matches groups whose stored name has zero-width characters")
    func addSessionMatchesPollutedStoredName() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "scratch\u{200B}",
                sessions: [
                    TerminalSession(
                        title: "shell 1",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        _ = store.addSession(groupName: "scratch")

        #expect(store.groups.count == 1)
        #expect(store.groups[0].sessions.count == 2)
    }

    @Test("restore sanitises group names")
    func restoreSanitisesGroupNames() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(
                    name: " \u{202E}scratch\u{0007}\u{200B} ",
                    sessions: [session]
                )
            ],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)

        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("restore drops a group whose name is empty after sanitisation")
    func restoreDropsGroupWithEmptySanitisedName() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "\u{202E}\u{200B}", sessions: [session])
            ],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)

        #expect(store.groups.isEmpty)
        #expect(store.selectedSessionID == nil)
    }

    @Test("restore merges snapshot entries that sanitise to the same name")
    func restoreMergesSanitisationCollisions() {
        let firstSession = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let secondSession = TerminalSession(
            title: "shell 2",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "scratch", sessions: [firstSession]),
                SessionGroup(name: "scratch\u{200B}", sessions: [secondSession])
            ],
            selectedSessionID: firstSession.id
        )

        let store = SessionStore(restoring: snapshot)

        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == "scratch")
        #expect(store.groups[0].sessions.map(\.id) == [firstSession.id, secondSession.id])
    }

    @Test("addWorkspaceGroup rejects a mixed-script confusable name")
    func rejectsMixedScriptGroupName() {
        let store = SessionStore(groups: [])

        // Cyrillic lookalikes mixed into an otherwise-Latin word (INT-485).
        #expect(store.addWorkspaceGroup(named: "\u{0421}l\u{0430}ud\u{0435}") == nil)
        #expect(store.groups.isEmpty)
    }

    @Test("renameGroup rejects a mixed-script confusable name")
    func renameGroupRejectsMixedScriptName() {
        let group = SessionGroup(name: "scratch", sessions: [])
        let store = SessionStore(groups: [group])

        #expect(store.renameGroup(id: group.id, to: "\u{0421}l\u{0430}ud\u{0435}") == false)
        #expect(store.groups.map(\.name) == ["scratch"])
    }

    @Test("addSession routes a mixed-script name to the canonical group")
    func addSessionRoutesMixedScriptNameToCanonical() {
        let store = SessionStore(groups: [])

        _ = store.addSession(groupName: "\u{0421}l\u{0430}ud\u{0435}")

        #expect(store.groups.map(\.name) == [SessionStore.canonicalDefaultGroupName])
    }

    @Test("restore quarantines a mixed-script group name instead of dropping it")
    func restoreQuarantinesMixedScriptGroupName() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "\u{0421}l\u{0430}ud\u{0435}", sessions: [session])
            ],
            selectedSessionID: session.id
        )

        // A name that was valid when persisted must never take its sessions
        // down with it on the next launch: policy rejection quarantines under
        // the canonical default name (INT-485 review finding).
        let store = SessionStore(restoring: snapshot)

        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == SessionStore.canonicalDefaultGroupName)
        #expect(store.groups[0].sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
    }

    @Test("restore merges snapshot entries that differ only by joiners")
    func restoreMergesJoinerOnlyCollisions() {
        let firstSession = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let secondSession = TerminalSession(
            title: "shell 2",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        // ZWNJ and ZWJ passed the sanitizer before INT-381, so unlike the
        // zero-width-space case above this pins the restore-merge behavior
        // the joiner-stripping fix introduces.
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "scratch\u{200C}", sessions: [firstSession]),
                SessionGroup(name: "scratch\u{200D}", sessions: [secondSession])
            ],
            selectedSessionID: firstSession.id
        )

        let store = SessionStore(restoring: snapshot)

        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == "scratch")
        #expect(store.groups[0].sessions.map(\.id) == [firstSession.id, secondSession.id])
    }

    @Test("createRemoteWorkspaceGroup creates a remote group and returns seeded session")
    func createRemoteWorkspaceGroupCreatesGroupAndReturnsSessionID() {
        let store = SessionStore(groups: [])
        let target = RemoteTarget(user: "ed", host: "box")!
        let sessionID = store.createRemoteWorkspaceGroup(
            named: "box",
            target: target
        )
        #expect(sessionID != nil)
        #expect(store.groups.count == 1)
        #expect(store.groups[0].name == "box")
        #expect(store.groups[0].remote == target)
        #expect(store.groups[0].sessions.count == 1)
        #expect(store.groups[0].sessions[0].id == sessionID)
        #expect(store.selectedSessionID == sessionID)
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
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

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

    @Test("remoteTarget returns nil for a session in a local group")
    func remoteTargetReturnsNilForLocalGroup() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(
            name: "main",
            remote: nil,
            sessions: [session]
        )
        let store = SessionStore(groups: [group], selectedSessionID: session.id)

        #expect(store.remoteTarget(forSessionID: session.id) == nil)
    }

    @Test("remoteTarget returns nil for an unknown session ID")
    func remoteTargetReturnsNilForUnknownID() {
        let store = SessionStore(groups: [])

        #expect(store.remoteTarget(forSessionID: UUID()) == nil)
    }
}
