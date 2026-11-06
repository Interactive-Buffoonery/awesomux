import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Companion pane rename")
struct CompanionPaneRenameTests {
    private let fingerprint = Data(repeating: 7, count: 32)

    private func fixture(renameScope: LocalAPITargetScope? = .allWorkspaces) -> (
        SessionStore, TerminalSession, LocalAPIRuntimeAuthority, LocalAPIConnectionGrant
    ) {
        let session = TerminalSession(title: "Shell", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Group", sessions: [session])])
        let grant = LocalAPIConnectionGrant(
            id: UUID(), label: "Phone", createdAt: Date(), credentialVerifier: Data(), revision: UUID(),
            statusScope: .allWorkspaces, kind: .companion,
            companion: .init(
                certificateFingerprint: fingerprint, transport: .lan, pairedAt: Date(), port: 1234,
                paneRenameScope: renameScope)
        )
        var state = LocalAPIAccessState(profile: "development")
        state.connections = [grant]
        return (store, session, LocalAPIRuntimeAuthority(state: state), grant)
    }

    private func apply(
        _ store: SessionStore, _ session: TerminalSession, _ authority: LocalAPIRuntimeAuthority,
        _ grant: LocalAPIConnectionGrant, title: String = "Backend", paneID: UUID? = nil,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        lease: LocalAPIAuthorizationLease? = nil
    ) throws {
        let authorized =
            try lease
            ?? authority.authorizeCompanion(
                connectionID: grant.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        try CompanionPaneRename.apply(
            request: .init(workspaceID: session.id, paneID: paneID ?? session.activePaneID, title: title),
            store: store, authority: authority, certificateFingerprint: fingerprint,
            lease: authorized, deadline: deadline)
    }

    @Test func requestRequiresExactMutationArguments() throws {
        let workspace = UUID(), pane = UUID()
        let valid: [String: Any] = [
            "schemaVersion": 1, "requestID": UUID().uuidString,
            "operation": "rename_pane", "connectionID": UUID().uuidString,
            "workspaceID": workspace.uuidString, "paneID": pane.uuidString, "title": "Backend",
        ]
        let decoded = try CompanionPaneRenameRequest.decode(valid)
        #expect(decoded.workspaceID == workspace && decoded.paneID == pane && decoded.title == "Backend")
        for key in ["schemaVersion", "requestID", "operation", "connectionID", "workspaceID", "paneID", "title"] {
            var missing = valid
            missing.removeValue(forKey: key)
            #expect(throws: LocalAPIError.invalidRequest) { try CompanionPaneRenameRequest.decode(missing) }
            for value in [NSNull(), true] as [Any] {
                var malformed = valid
                malformed[key] = value
                #expect(throws: LocalAPIError.invalidRequest) { try CompanionPaneRenameRequest.decode(malformed) }
            }
        }
        for key in ["workspaceID", "paneID", "title", "requestID", "operation", "connectionID", "profile"] {
            var numeric = valid
            numeric[key] = 1
            #expect(throws: LocalAPIError.invalidRequest) { try CompanionPaneRenameRequest.decode(numeric) }
        }
        var newer = valid
        newer["schemaVersion"] = 99
        #expect(throws: LocalAPIError.unsupportedVersion) { try CompanionPaneRenameRequest.decode(newer) }
        for key in ["limit", "cursor", "targetVersion", "source", "credential", "terminalPreviewAllowed"] {
            var extra = valid
            extra[key] = "unexpected"
            #expect(throws: LocalAPIError.invalidRequest) { try CompanionPaneRenameRequest.decode(extra) }
        }
        var malformedID = valid
        malformedID["paneID"] = "not-a-uuid"
        #expect(throws: LocalAPIError.invalidRequest) { try CompanionPaneRenameRequest.decode(malformedID) }
    }

    @Test func legacyGrantCannotMutate() throws {
        let (store, session, authority, grant) = fixture(renameScope: nil)
        #expect(throws: LocalAPIError.permissionDenied) { try apply(store, session, authority, grant) }
        #expect(store.session(id: session.id)?.activePane?.title == "Shell")
    }

    @Test func renamePinsAndPersistsNativeTitleWithoutSelecting() throws {
        let (store, session, authority, grant) = fixture()
        let selected = store.selectedSessionID
        try apply(store, session, authority, grant)
        let restored = SessionStore(restoring: store.snapshot())
        #expect(restored.session(id: session.id)?.activePane?.title == "Backend")
        #expect(restored.session(id: session.id)?.activePane?.isTitleUserEdited == true)
        #expect(store.selectedSessionID == selected)
    }

    @Test func failuresDoNotMutate() throws {
        let (store, session, authority, grant) = fixture()
        #expect(throws: LocalAPIError.invalidTitle) { try apply(store, session, authority, grant, title: " \n ") }
        #expect(throws: LocalAPIError.staleTarget) { try apply(store, session, authority, grant, paneID: UUID()) }
        #expect(throws: LocalAPIError.timeout) {
            try apply(store, session, authority, grant, deadline: .now.advanced(by: .seconds(-1)))
        }
        #expect(store.session(id: session.id)?.activePane?.title == "Shell")
    }

    @Test func documentGroupIsNotRenameable() throws {
        let (_, session, authority, grant) = fixture()
        let group = DocumentGroup(browsingFrom: session.activePaneID)
        let mixed = TerminalSession(
            title: "Mixed", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical, first: session.layout, second: .documentGroup(group))))
        let store = SessionStore(groups: [SessionGroup(name: "Group", sessions: [mixed])])
        #expect(throws: LocalAPIError.nonterminalTarget) { try apply(store, mixed, authority, grant, paneID: group.id) }
    }

    @Test func cancelledTaskDoesNotMutate() async throws {
        let (store, session, authority, grant) = fixture()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: LocalAPIError.cancelled) { try apply(store, session, authority, grant) }
        }
        await task.value
        #expect(store.session(id: session.id)?.activePane?.title == "Shell")
    }

    @Test func metadataMissingRenameScopeDefaultsDenied() throws {
        let metadata = LocalAPICompanionMetadata(
            certificateFingerprint: fingerprint, transport: .lan,
            pairedAt: Date(), port: 1234)
        let data = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: data).paneRenameScope == nil)
    }

    @Test func macControlPersistsAndInvalidatesOriginalLease() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: directory)
        let phone = try access.registerCompanion(
            phoneName: "Phone", certificateFingerprint: fingerprint,
            transport: .lan, port: 1234)
        let original = try access.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id,
            certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        #expect(original.paneRenameScope == nil)
        try access.updateCompanionPaneRenameScope(connectionID: phone.id, scope: .allWorkspaces)
        let enabled = try access.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id,
            certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        #expect(enabled.paneRenameScope == .allWorkspaces)
        let persisted = try LocalAPIContract.decoder().decode(
            LocalAPIAccessState.self, from: Data(contentsOf: directory.appending(path: "LocalAPI/access.json")))
        #expect(persisted.connections.first(where: { $0.id == phone.id })?.companion?.paneRenameScope == .allWorkspaces)
        #expect(enabled.connectionRevision != original.connectionRevision)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionPaneRename(certificateFingerprint: fingerprint, lease: original) {
                Issue.record("Stale lease mutated")
            }
        }
        try access.updateCompanionPaneRenameScope(connectionID: phone.id, scope: nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionPaneRename(certificateFingerprint: fingerprint, lease: enabled) {
                Issue.record("Disabled grant mutated")
            }
        }
    }

    @Test func revocationAfterAuthorizationPreventsMutation() throws {
        let (store, session, authority, grant) = fixture()
        let lease = try authority.authorizeCompanion(
            connectionID: grant.id, certificateFingerprint: fingerprint,
            operation: .connectionStatus
        ).get()
        authority.replace(with: LocalAPIAccessState(profile: "development"))
        #expect(throws: LocalAPIError.permissionDenied) { try apply(store, session, authority, grant, lease: lease) }
        #expect(store.session(id: session.id)?.activePane?.title == "Shell")
    }
}
