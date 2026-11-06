import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Companion terminal create")
struct CompanionTerminalCreateTests {
    private let fingerprint = Data(repeating: 7, count: 32)

    private func fixture(input: Bool = true, scope: LocalAPITargetScope? = .allWorkspaces) -> (
        SessionStore, LocalAPIRuntimeAuthority, LocalAPIAuthorizationLease
    ) {
        let store = SessionStore(groups: [])
        let grant = LocalAPIConnectionGrant(
            id: UUID(), label: "Phone", createdAt: Date(), credentialVerifier: Data(), revision: UUID(),
            statusScope: .allWorkspaces, kind: .companion,
            companion: .init(
                certificateFingerprint: fingerprint, transport: .lan, pairedAt: Date(), port: 1234,
                terminalWatchScope: scope, terminalInputAllowed: input))
        var state = LocalAPIAccessState(profile: "development")
        state.connections = [grant]
        let authority = LocalAPIRuntimeAuthority(state: state)
        let lease = try! authority.authorizeCompanion(
            connectionID: grant.id, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        return (store, authority, lease)
    }

    private func create(
        _ store: SessionStore, _ authority: LocalAPIRuntimeAuthority, _ lease: LocalAPIAuthorizationLease,
        workspaceID: UUID? = nil, deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws -> CompanionTerminalCreated {
        try CompanionTerminalCreate.apply(
            request: .init(workspaceID: workspaceID), store: store, defaultGroup: "Default",
            authority: authority, certificateFingerprint: fingerprint, lease: lease, deadline: deadline)
    }

    @Test func inputOffAndMissingTerminalGrantCannotCreate() {
        for (input, scope): (Bool, LocalAPITargetScope?) in [(false, .allWorkspaces), (true, nil)] {
            let (store, authority, lease) = fixture(input: input, scope: scope)
            #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease) }
            #expect(store.groups.isEmpty)
        }
    }

    @Test func mismatchedCertificateCannotCreate() {
        let (store, authority, lease) = fixture()
        #expect(throws: LocalAPIError.permissionDenied) {
            try CompanionTerminalCreate.apply(
                request: .init(workspaceID: nil), store: store, defaultGroup: "Default",
                authority: authority, certificateFingerprint: Data(repeating: 8, count: 32),
                lease: lease, deadline: .now.advanced(by: .seconds(5)))
        }
        #expect(store.groups.isEmpty)
    }

    @Test func replacedRevisionOnSameConnectionCannotCreate() throws {
        let (store, authority, lease) = fixture()
        var state = LocalAPIAccessState(profile: "development")
        state.connections = [
            LocalAPIConnectionGrant(
                id: lease.connectionID, label: "Phone", createdAt: Date(), credentialVerifier: Data(), revision: UUID(),
                statusScope: lease.statusScope, kind: .companion,
                companion: .init(
                    certificateFingerprint: fingerprint, transport: .lan, pairedAt: Date(), port: 1234,
                    terminalWatchScope: lease.terminalWatchScope, terminalInputAllowed: lease.terminalInputAllowed))
        ]
        authority.replace(with: state)
        #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease) }
        #expect(store.groups.isEmpty)
        let currentLease = try authority.authorizeCompanion(
            connectionID: lease.connectionID, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        _ = try create(store, authority, currentLease)
        #expect(store.groups.flatMap(\.sessions).count == 1)
    }

    @Test func remoteOwnedWorkspaceCannotCreateOrDuplicateAttachment() throws {
        let (store, authority, lease) = fixture()
        let host = try #require(RemoteTarget(parsing: "example.test"))
        let name = try #require(RemoteSessionName(rawValue: "work"))
        let remotePane = TerminalPane(
            title: "Remote", workingDirectory: "~", executionPlan: .ssh(SSHExecution(target: host, remoteSessionName: name)))
        let session = TerminalSession(title: "Remote", workingDirectory: "~", layout: .pane(remotePane))
        store.insertSession(session, groupName: "Remote")
        let before = store.snapshot()
        #expect(throws: LocalAPIError.remoteWorkspaceUnsupported) { try create(store, authority, lease, workspaceID: session.id) }
        #expect(store.snapshot() == before)
    }

    @Test func workspaceOutsideGrantCannotSplitOrCreateWorkspace() throws {
        let allowed = UUID()
        let (store, authority, lease) = fixture(scope: .persistentWorkspaces([allowed]))
        let workspaceID = store.addSession()
        #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease, workspaceID: workspaceID) }
        #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease) }
        #expect(store.session(id: workspaceID)?.panes.count == 1)
    }

    @Test func createsLocalShellInDefaultGroupWithOpenableIdentity() throws {
        let (store, authority, lease) = fixture()
        let result = try create(store, authority, lease)
        let session = try #require(store.session(id: result.workspaceID))
        let pane = try #require(session.layout.pane(id: result.paneID))
        #expect(store.groups.first?.name == "Default")
        #expect(pane.executionPlan == .local)
        #expect(pane.agentKind == .shell)
        #expect(store.localAPITerminalWatchTarget(paneID: pane.id)?.targetVersion == result.targetVersion)
    }

    @Test func defaultRemoteGroupStillCreatesLocalShell() throws {
        let (store, authority, lease) = fixture()
        let host = try #require(RemoteTarget(parsing: "example.test"))
        _ = store.createRemoteWorkspaceGroup(named: "Default", target: host)
        let result = try create(store, authority, lease)
        #expect(store.session(id: result.workspaceID)?.activePane?.executionPlan == .local)
    }

    @Test func splitInSSHWorkspaceInheritsExecutionLocation() throws {
        let (store, authority, lease) = fixture()
        let host = try #require(RemoteTarget(parsing: "example.test"))
        var pane = TerminalPane(title: "Remote", workingDirectory: "/local/launch", executionPlan: .ssh(SSHExecution(target: host)))
        pane.remoteWorkingDirectory = "/srv/work"
        let session = TerminalSession(title: "Remote", workingDirectory: pane.workingDirectory, layout: .pane(pane))
        store.insertSession(session, groupName: "Remote")
        let result = try create(store, authority, lease, workspaceID: session.id)
        let split = try #require(store.session(id: session.id)?.layout.pane(id: result.paneID))
        #expect(split.executionPlan == pane.executionPlan)
        #expect(split.workingDirectory == pane.workingDirectory)
        #expect(split.remoteWorkingDirectory == nil)
        let nativeStore = SessionStore(groups: [SessionGroup(name: "Remote", sessions: [session])], selectedSessionID: session.id)
        let nativeID = try #require(nativeStore.splitActivePane(orientation: .vertical))
        let nativeSplit = try #require(nativeStore.session(id: session.id)?.layout.pane(id: nativeID))
        #expect(split.executionPlan == nativeSplit.executionPlan)
        #expect(split.workingDirectory == nativeSplit.workingDirectory)
        #expect(split.remoteWorkingDirectory == nativeSplit.remoteWorkingDirectory)
        #expect(split.id != pane.id)
        #expect(store.session(id: session.id)?.panes.count == 2)
    }

    @Test func expiredRevokedAndMissingTargetsDoNotMutate() throws {
        let (store, authority, lease) = fixture()
        #expect(throws: LocalAPIError.timeout) {
            try create(store, authority, lease, deadline: .now.advanced(by: .seconds(-1)))
        }
        #expect(throws: LocalAPIError.staleTarget) { try create(store, authority, lease, workspaceID: UUID()) }
        authority.replace(with: LocalAPIAccessState(profile: "development"))
        #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease) }
        #expect(store.groups.isEmpty)
    }

    @Test func workspaceGrantAllowsSplitButPaneGrantDoesNot() throws {
        let workspace = TerminalSession(title: "Shell", workingDirectory: "~")
        for (scope, allowed): (LocalAPITargetScope, Bool) in [
            (.persistentWorkspaces([workspace.id]), true), (.persistentPanes([workspace.activePaneID]), false),
        ] {
            let (store, authority, lease) = fixture(scope: scope)
            store.insertSession(workspace, groupName: "Work")
            if allowed {
                let result = try create(store, authority, lease, workspaceID: workspace.id)
                #expect(result.workspaceID == workspace.id)
                #expect(store.session(id: workspace.id)?.panes.count == 2)
            } else {
                #expect(throws: LocalAPIError.permissionDenied) { try create(store, authority, lease, workspaceID: workspace.id) }
                #expect(store.session(id: workspace.id)?.panes.count == 1)
            }
        }
    }

    @Test func unavailablePanesReturnSpecificReasonsWithoutHydrating() throws {
        let (_, authority, lease) = fixture()
        let exited = TerminalPane(title: "Exited", workingDirectory: "~", foregroundProcessLiveness: .exited, executionPlan: .local)
        let host = try #require(RemoteTarget(parsing: "example.test"))
        var disconnected = TerminalPane(title: "Disconnected", workingDirectory: "~", executionPlan: .local)
        disconnected.remoteReconnect = .disconnected(.init(target: host))
        for (pane, reason) in [(exited, LocalAPIError.paneExited), (disconnected, .paneDisconnected)] {
            let workspace = TerminalSession(title: "Unavailable", workingDirectory: "~", layout: .pane(pane))
            let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [workspace])])
            let target = try #require(store.localAPITerminalWatchTarget(paneID: pane.id))
            #expect(throws: reason) {
                try CompanionTerminalOpen.prepare(
                    paneID: pane.id, targetVersion: target.targetVersion, store: store,
                    authority: authority, certificateFingerprint: fingerprint, lease: lease,
                    deadline: .now.advanced(by: .seconds(5))
                ) { _, _ in Issue.record("Unavailable pane was hydrated") }
            }
        }
    }

    @Test func requestAcceptsOnlyOptionalWorkspaceIdentity() throws {
        let base: [String: Any] = [
            "schemaVersion": 1, "requestID": UUID().uuidString, "operation": "create_terminal",
            "connectionID": UUID().uuidString,
        ]
        #expect(try CompanionTerminalCreateRequest.decode(base).workspaceID == nil)
        var split = base
        let workspaceID = UUID()
        split["workspaceID"] = workspaceID.uuidString
        #expect(try CompanionTerminalCreateRequest.decode(split).workspaceID == workspaceID)
        for key in ["paneID", "targetVersion", "title", "source", "grid", "credential"] {
            var invalid = base
            invalid[key] = "unexpected"
            #expect(throws: LocalAPIError.invalidRequest) { try CompanionTerminalCreateRequest.decode(invalid) }
        }
        for value in [NSNull(), true, 1, "bad-uuid"] as [Any] {
            var invalid = base
            invalid["workspaceID"] = value
            #expect(throws: LocalAPIError.invalidRequest) { try CompanionTerminalCreateRequest.decode(invalid) }
        }
    }

    @Test func restoredUnvisitedPaneIsVersionedAndHydratedWithoutSelection() throws {
        let (original, authority, lease) = fixture(input: false)
        let workspaceID = original.addSession()
        _ = original.addSession()
        let store = SessionStore(restoring: original.snapshot())
        let pane = try #require(store.session(id: workspaceID)?.activePane)
        let selection = store.selectedSessionID
        #expect(selection != workspaceID)
        let roster = store.companionWorkspaces { _ in nil }
        let version = try #require(roster.first?.panes.first?.targetVersion.flatMap(UUID.init(uuidString:)))
        #expect(PaneAvailability.of(.terminal(pane)) == .awaitingHydration)
        var hydrated: UUID?
        let target = try CompanionTerminalOpen.prepare(
            paneID: pane.id, targetVersion: version, store: store,
            authority: authority, certificateFingerprint: fingerprint, lease: lease,
            deadline: .now.advanced(by: .seconds(5))
        ) { session, terminal in
            #expect(session.id == workspaceID)
            hydrated = terminal.id
        }
        #expect(hydrated == pane.id)
        #expect(target.localSessionName == pane.terminalSessionID.rawValue)
        #expect(target.targetVersion == version)
        #expect(store.selectedSessionID == selection)
    }

    @Test func socketReadinessObservesCreationAndAlreadyPresentSocket() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appending(path: "terminal")
        let waiting = Task { @MainActor in
            try await CompanionTerminalOpen.waitForSocket(at: socket.path, deadline: .now.advanced(by: .seconds(30)))
        }
        await Task.yield()
        #expect(FileManager.default.createFile(atPath: socket.path, contents: Data()))
        try await waiting.value
        try await CompanionTerminalOpen.waitForSocket(at: socket.path, deadline: .now.advanced(by: .seconds(30)))
    }

    @Test func socketReadinessIsBoundedAndCancellationDoesNotWaitForCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "missing").path
        await #expect(throws: LocalAPIError.timeout) {
            try await CompanionTerminalOpen.waitForSocket(at: path, deadline: .now.advanced(by: .milliseconds(20)))
        }
        let waiting = Task { @MainActor in
            try await CompanionTerminalOpen.waitForSocket(at: path, deadline: .now.advanced(by: .seconds(2)))
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func expiredHydrationAuthorityCannotSpawn() throws {
        let (store, authority, lease) = fixture()
        let workspaceID = store.addSession()
        let pane = try #require(store.session(id: workspaceID)?.activePane)
        let target = try #require(store.localAPITerminalWatchTarget(paneID: pane.id))
        let request = CompanionTerminalOpen.SpawnAuthority(
            paneID: pane.id, targetVersion: target.targetVersion, store: store,
            authority: authority, certificateFingerprint: fingerprint, lease: lease,
            deadline: .now.advanced(by: .seconds(-1)))
        #expect(throws: LocalAPIError.timeout) {
            try request.perform { Issue.record("Expired hydration spawned a surface") }
        }
    }

    @Test func unauthorizedWatchDoesNotHydrate() throws {
        let (store, authority, lease) = fixture(scope: nil)
        let workspace = store.addSession()
        let pane = try #require(store.session(id: workspace)?.activePane)
        let target = try #require(store.localAPITerminalWatchTarget(paneID: pane.id))
        #expect(throws: LocalAPIError.permissionDenied) {
            try CompanionTerminalOpen.prepare(
                paneID: pane.id, targetVersion: target.targetVersion, store: store,
                authority: authority, certificateFingerprint: fingerprint, lease: lease,
                deadline: .now.advanced(by: .seconds(5))
            ) { _, _ in Issue.record("Denied phone hydrated a pane") }
        }
    }

    @Test func statusCreateHintsFollowInputAndTerminalScope() {
        let cases: [(Bool, LocalAPITargetScope?, workspace: Bool, pane: Bool)] = [
            (true, .allWorkspaces, true, true),
            (true, .persistentWorkspaces([UUID()]), false, true),
            (true, .persistentPanes([UUID()]), false, false),
            (true, nil, false, false),
            (false, .allWorkspaces, false, false),
        ]
        for (input, scope, workspace, pane) in cases {
            let lease = fixture(input: input, scope: scope).2
            #expect(lease.companionCanCreateWorkspace == workspace)
            #expect(lease.companionCanCreatePane == pane)
        }
    }
}
