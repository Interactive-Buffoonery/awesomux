import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing
import os

@MainActor
@Suite("Companion preview permission")
struct CompanionPreviewPermissionTests {
    private let fingerprint = Data(repeating: 3, count: 32)
    private func lease(_ access: LocalAPIAccessStore, _ id: UUID, fingerprint: Data? = nil) throws -> LocalAPIAuthorizationLease {
        try access.runtimeAuthority.authorizeCompanion(
            connectionID: id, certificateFingerprint: fingerprint ?? self.fingerprint, operation: .connectionStatus
        ).get()
    }

    @Test func legacyMetadataDefaultsOffAndTrueRoundTrips() throws {
        let metadata = LocalAPICompanionMetadata(
            certificateFingerprint: fingerprint, transport: .lan, pairedAt: Date(), port: 1234, terminalPreviewAllowed: true)
        let encoded = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: encoded).terminalPreviewAllowed)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "terminalPreviewAllowed")
        #expect(
            try !JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONSerialization.data(withJSONObject: object))
                .terminalPreviewAllowed)
    }

    @Test func selfUpdatePersistsRotatesLeaseAndLeavesOtherPhoneAlone() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let phone = try access.registerCompanion(phoneName: "One", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        let otherFingerprint = Data(repeating: 4, count: 32)
        let other = try access.registerCompanion(phoneName: "Two", certificateFingerprint: otherFingerprint, transport: .lan, port: 1234)
        let invalidations = OSAllocatedUnfairLock(initialState: [UUID]())
        access.setCompanionInvalidationHandler { id in
            if let id { invalidations.withLock { $0.append(id) } }
        }
        try access.setGloballyEnabled(true)
        let registration = try access.prepareRegistration(label: "Outside", statusScope: .allWorkspaces)
        try access.activateRegistration(registration)
        let bearerRequest = LocalAPIRequest(
            profile: "development", operation: .connectionStatus, connectionID: registration.connection.id,
            credential: LocalAPICredential.encode(registration.credential)
        )
        let bearerLease = try access.runtimeAuthority.provider.authorize(bearerRequest).get()
        let old = try lease(access, phone.id)
        let otherLease = try lease(access, other.id, fingerprint: otherFingerprint)
        #expect(!old.terminalPreviewAllowed)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.setCompanionTerminalPreviewAllowed(
                connectionID: phone.id, allowed: true, certificateFingerprint: otherFingerprint, expectedLease: old)
        }
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.setCompanionTerminalPreviewAllowed(
                connectionID: other.id, allowed: true, certificateFingerprint: fingerprint, expectedLease: old)
        }
        let enabled = try access.setCompanionTerminalPreviewAllowed(
            connectionID: phone.id, allowed: true, certificateFingerprint: fingerprint, expectedLease: old)
        #expect(enabled.terminalPreviewAllowed)
        #expect(enabled.connectionRevision != old.connectionRevision)
        #expect(try lease(access, other.id, fingerprint: otherFingerprint) == otherLease)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: old) {
                Issue.record("Old capture wrote"); return 1
            }
        }
        let repeated = try access.setCompanionTerminalPreviewAllowed(
            connectionID: phone.id, allowed: true, certificateFingerprint: fingerprint, expectedLease: enabled)
        #expect(repeated == enabled)
        #expect(invalidations.withLock { $0 } == [phone.id])
        #expect(try access.runtimeAuthority.provider.authorize(bearerRequest).get() == bearerLease)
        #expect(!bearerLease.terminalPreviewAllowed)
        #expect(access.state.connections.first(where: { $0.id == registration.connection.id })?.companion == nil)
        let persisted = try Data(contentsOf: home.appending(path: "LocalAPI/access.json"))
        #expect(
            try JSONDecoder.iso8601.decode(LocalAPIAccessState.self, from: persisted).connections.first(where: { $0.id == phone.id })?
                .companion?.terminalPreviewAllowed == true)
        try access.updateCompanionTerminalPreviewAllowed(connectionID: phone.id, allowed: false)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.setCompanionTerminalPreviewAllowed(
                connectionID: phone.id, allowed: true, certificateFingerprint: fingerprint, expectedLease: enabled)
        }
        let disabled = try lease(access, phone.id)
        #expect(!disabled.terminalPreviewAllowed)
        #expect(invalidations.withLock { $0 } == [phone.id, phone.id])
        #expect(try lease(access, other.id, fingerprint: otherFingerprint) == otherLease)
        try access.revoke(connectionID: phone.id)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: disabled) {
                Issue.record("Revoked permission acknowledgement wrote"); return 1
            }
        }
        #expect(
            !LocalAPIAuthorizationLease(
                connectionID: UUID(), globalRevision: UUID(), connectionRevision: UUID(), statusScope: .allWorkspaces
            ).terminalPreviewAllowed)
    }

    @Test(arguments: ["absent", "true", "number", "null"])
    func strictPersistedMetadataMigration(value: String) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var access: LocalAPIAccessStore? = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let phone = try #require(access).registerCompanion(
            phoneName: "Legacy", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        access = nil
        let file = home.appending(path: "LocalAPI/access.json")
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var connections = try #require(root["connections"] as? [[String: Any]])
        var metadata = try #require(connections[0]["companion"] as? [String: Any])
        switch value {
        case "absent": metadata.removeValue(forKey: "terminalPreviewAllowed")
        case "true": metadata["terminalPreviewAllowed"] = true
        case "number": metadata["terminalPreviewAllowed"] = 1
        default: metadata["terminalPreviewAllowed"] = NSNull()
        }
        connections[0]["companion"] = metadata
        root["connections"] = connections
        try JSONSerialization.data(withJSONObject: root).write(to: file)
        let restored = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        if value == "absent" || value == "true" {
            #expect(restored.loadFailure == nil)
            #expect(try lease(restored, phone.id).terminalPreviewAllowed == (value == "true"))
        } else {
            #expect(restored.loadFailure != nil)
            #expect(throws: LocalAPIError.permissionDenied) { try lease(restored, phone.id) }
        }
    }

    @Test(arguments: [true, false]) func failedSaveDeniesForRunUntilRetry(allowed: Bool) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let phone = try access.registerCompanion(
            phoneName: "One", certificateFingerprint: fingerprint, transport: .lan, port: 1234, terminalPreviewAllowed: !allowed)
        let old = try lease(access, phone.id)
        let directory = home.appending(path: "LocalAPI")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: LocalAPIAccessFailure.persistenceFailed) {
            try access.updateCompanionTerminalPreviewAllowed(connectionID: phone.id, allowed: allowed)
        }
        #expect(access.persistenceFailureMessage != nil)
        #expect(throws: LocalAPIError.permissionDenied) { try lease(access, phone.id) }
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: old) {
                Issue.record("Failed opt-out leaked"); return 1
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try access.retryPersistence()
        #expect(try lease(access, phone.id).terminalPreviewAllowed == allowed)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
