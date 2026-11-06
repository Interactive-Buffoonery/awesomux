import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing

@MainActor
@Suite("Companion preview and rename grant coexistence")
struct CompanionGrantCoexistenceTests {
    @Test func metadataRoundTripPreservesBothPermissions() throws {
        let scope = LocalAPITargetScope.allWorkspaces
        let metadata = LocalAPICompanionMetadata(
            certificateFingerprint: Data(repeating: 5, count: 32), transport: .lan,
            pairedAt: Date(timeIntervalSince1970: 0), port: 1234,
            paneRenameScope: scope, pairingVersion: 2, terminalPreviewAllowed: true
        )
        let decoded = try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded == metadata)
        #expect(decoded.paneRenameScope == scope)
        #expect(decoded.terminalPreviewAllowed)
        #expect(decoded.pairingVersion == 2)
        #expect(decoded.allows(.lan) && decoded.allows(.tailscale))
    }

    @Test func independentTogglesPreserveOtherGrantAndInvalidateOldLease() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var access: LocalAPIAccessStore? = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let fingerprint = Data(repeating: 5, count: 32)
        let phone = try #require(access).registerCompanion(
            phoneName: "Phone", certificateFingerprint: fingerprint, transport: .lan, port: 1234, pairingVersion: 2)
        func lease(_ store: LocalAPIAccessStore) throws -> LocalAPIAuthorizationLease {
            try store.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        }
        try #require(access).updateCompanionPaneRenameScope(connectionID: phone.id, scope: .allWorkspaces)
        let renameOnly = try lease(#require(access))
        #expect(renameOnly.paneRenameScope == .allWorkspaces && !renameOnly.terminalPreviewAllowed)
        let both = try #require(access).setCompanionTerminalPreviewAllowed(
            connectionID: phone.id, allowed: true, certificateFingerprint: fingerprint, expectedLease: renameOnly)
        #expect(both.paneRenameScope == .allWorkspaces && both.terminalPreviewAllowed)
        #expect(throws: LocalAPIError.permissionDenied) {
            try #require(access).runtimeAuthority.commitCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, lease: renameOnly
            ) {
                Issue.record("Old rename lease wrote"); return 1
            }
        }
        access = nil
        access = LocalAPIAccessStore.reopened(profile: "development", supportDirectoryURL: home)
        #expect(try #require(access).loadFailure == nil)
        #expect(try lease(#require(access)) == both)
        try #require(access).updateCompanionPaneRenameScope(connectionID: phone.id, scope: nil)
        let previewOnly = try lease(#require(access))
        #expect(previewOnly.paneRenameScope == nil && previewOnly.terminalPreviewAllowed)
        #expect(throws: LocalAPIError.permissionDenied) {
            try #require(access).runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: both)
            {
                Issue.record("Old dual-grant lease wrote"); return 1
            }
        }
        try #require(access).updateCompanionPaneRenameScope(connectionID: phone.id, scope: .allWorkspaces)
        try #require(access).updateCompanionTerminalPreviewAllowed(connectionID: phone.id, allowed: false)
        let renameAgain = try lease(#require(access))
        #expect(renameAgain.paneRenameScope == .allWorkspaces && !renameAgain.terminalPreviewAllowed)
        access = nil
        let restored = LocalAPIAccessStore.reopened(profile: "development", supportDirectoryURL: home)
        #expect(restored.loadFailure == nil)
        #expect(try lease(restored) == renameAgain)
        #expect(restored.state.connections.first?.companion?.pairingVersion == 2)
    }
}
