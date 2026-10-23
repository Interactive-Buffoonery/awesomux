import AwesoMuxCompanionProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

// Failure modes: a grant revoked after recording must suppress a not-yet-written
// fallback choice while still waking the hook with a choice-free terminal reply.
// Fixture transport success must never change the release gate.
@Suite @MainActor struct CompanionDecisionIntegrationTests {
    @Test func productionProviderGateRemainsClosed() {
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: "2.1.302"))
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: nil))
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "codex", version: "future"))
    }

    // Persisted workspace grants must migrate without enabling an explicit off switch.
    enum LegacyDecisionGrant: CaseIterable { case missing, empty, granted, explicitOff, explicitOn }

    @Test(arguments: LegacyDecisionGrant.allCases)
    func legacyDecisionGrantMigratesAndPersists(grant: LegacyDecisionGrant) throws {
        let enabled = grant == .granted || grant == .explicitOn
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var access: LocalAPIAccessStore? = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        let phone = try #require(access).registerCompanion(
            phoneName: "Phone", certificateFingerprint: Data(repeating: 7, count: 32), transport: .lan, port: 1234)
        let file = root.appendingPathComponent("LocalAPI/access.json")
        access = nil
        _ = try rewriteLegacyDecisionMetadata(at: file) { metadata in
            switch grant {
            case .missing: break
            case .empty: metadata["decideWorkspaceIDs"] = [String]()
            case .granted: metadata["decideWorkspaceIDs"] = [UUID().uuidString]
            case .explicitOff:
                metadata["decideWorkspaceIDs"] = [UUID().uuidString]
                metadata["decisionsAllowed"] = false
            case .explicitOn:
                metadata["decideWorkspaceIDs"] = [String]()
                metadata["decisionsAllowed"] = true
            }
        }
        let migrated = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        #expect(migrated.loadFailure == nil)
        #expect(migrated.state.connections.first { $0.id == phone.id }?.companion?.decisionsAllowed == enabled)
        let saved = try LocalAPIContract.decoder().decode(LocalAPIAccessState.self, from: Data(contentsOf: file))
        #expect(saved.connections.first?.companion?.decisionsAllowed == enabled)
        let persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let savedConnections = try #require(persisted["connections"] as? [[String: Any]])
        let savedMetadata = try #require(savedConnections[0]["companion"] as? [String: Any])
        #expect(savedMetadata["decideWorkspaceIDs"] == nil)
    }

    @Test func malformedLegacyDecisionGrantRemainsDenied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-invalid-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var access: LocalAPIAccessStore? = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        _ = try #require(access).registerCompanion(
            phoneName: "Phone", certificateFingerprint: Data(repeating: 7, count: 32), transport: .lan, port: 1234)
        let file = root.appendingPathComponent("LocalAPI/access.json")
        access = nil
        let legacy = try rewriteLegacyDecisionMetadata(at: file) { metadata in
            let workspace = UUID().uuidString
            metadata["decideWorkspaceIDs"] = [workspace.uppercased(), workspace.lowercased()]
        }
        let denied = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        #expect(denied.loadFailure == .preservedInvalidState)
        #expect(denied.state.connections.isEmpty)
        #expect(try Data(contentsOf: file) == legacy)
    }

    @Test func failedMigrationPreservesConnectionsAndAllowsRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-migration-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var access: LocalAPIAccessStore? = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        let fingerprint = Data(repeating: 7, count: 32)
        let phone = try #require(access).registerCompanion(
            phoneName: "Phone", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        let outside = try #require(access).prepareRegistration(label: "Outside", statusScope: .allWorkspaces)
        try #require(access).activateRegistration(outside)
        try #require(access).setGloballyEnabled(true)
        let directory = root.appendingPathComponent("LocalAPI")
        let file = directory.appendingPathComponent("access.json")
        access = nil
        _ = try rewriteLegacyDecisionMetadata(at: file) { metadata in
            metadata["decideWorkspaceIDs"] = [UUID().uuidString]
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let migrated = LocalAPIAccessStore(
            profile: "development", supportDirectoryURL: root, fileManager: MigrationReadOnlyFileManager())
        #expect(migrated.loadFailure == nil)
        #expect(migrated.state.connections.count == 2)
        #expect(migrated.persistenceFailureMessage != nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try migrated.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        }
        let outsideRequest = LocalAPIRequest(
            profile: "development", operation: .connectionStatus, connectionID: outside.connection.id,
            credential: LocalAPICredential.encode(outside.credential))
        #expect(try migrated.runtimeAuthority.provider.authorize(outsideRequest).get().connectionID == outside.connection.id)
        #expect(throws: LocalAPIAccessFailure.persistenceFailed) { try migrated.revoke(connectionID: outside.connection.id) }
        #expect(throws: LocalAPIError.permissionDenied) {
            try migrated.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try migrated.retryPersistence()
        #expect(migrated.persistenceFailureMessage == nil)
        let lease = try migrated.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        #expect(lease.decisionsAllowed)
    }

    private func rewriteLegacyDecisionMetadata(at file: URL, change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var connections = try #require(object["connections"] as? [[String: Any]])
        let index = try #require(connections.firstIndex { $0["kind"] as? String == "companion" })
        var metadata = try #require(connections[index]["companion"] as? [String: Any])
        metadata.removeValue(forKey: "decisionsAllowed")
        change(&metadata)
        connections[index]["companion"] = metadata
        object["connections"] = connections
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: file)
        return data
    }

    @Test func workspaceCreatedAfterGrantHasVisibleDecisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-future-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        let fingerprint = Data(repeating: 7, count: 32)
        let phone = try access.registerCompanion(phoneName: "Phone", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        let pairing = CompanionPairingCoordinator(profile: .development(worktreeID: nil), accessStore: access)
        defer { pairing.stop() }
        try pairing.setDecisionsAllowed(true, for: phone)
        let lease = try access.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        let coordinator = LocalPermissionCoordinator(announcement: { _ in })
        defer { coordinator.retireAll() }
        let workspace = UUID(), pane = UUID()
        let endpoint = try #require(
            coordinator.install(
                workspaceID: workspace, paneID: pane, eventFile: root.appendingPathComponent("events.jsonl")))
        let request = LocalPermissionRequest(
            target: endpoint.target, providerSessionID: "fixture", invocationID: UUID(), toolUseID: nil,
            helperPID: getpid(), helperStartMicroseconds: try #require(LocalPermissionFiles.processStartMicroseconds(getpid())),
            expiresAt: Date().addingTimeInterval(120), tool: "Bash", summary: "echo future workspace")
        #expect(LocalPermissionFiles.write(request, at: endpoint.file("req", id: request.invocationID)))
        try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .pending })
        let result = try coordinator.remoteResponse(
            answer: nil, deviceID: phone.id, deviceName: phone.label,
            authorize: { body in
                try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: lease, body: body)
            }, eligible: { $0 == endpoint.target }, fixture: true)
        #expect(result.pending.map(\.identity) == [request.identity.companionIdentity])
        try coordinator.validateRemoteTargets(result.pending.map(\.identity), eligible: { $0 == endpoint.target })
        #expect(throws: LocalAPIError.permissionDenied) {
            try coordinator.validateRemoteTargets(result.pending.map(\.identity), eligible: { _ in false })
        }
    }

    enum RevocationStage: CaseIterable { case recorded, claimed, escaped }

    @Test(arguments: [false, true], RevocationStage.allCases)
    func revokedWinnerCannotPublishAnswer(socketTransport: Bool, stage: RevocationStage)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-decision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = LocalPermissionCoordinator(announcement: { _ in })
        defer { coordinator.retireAll() }
        let workspace = UUID(), pane = UUID()
        let endpoint = try #require(
            coordinator.install(
                workspaceID: workspace, paneID: pane,
                eventFile: root.appendingPathComponent("events.jsonl")))
        let request = LocalPermissionRequest(
            target: endpoint.target, providerSessionID: "fixture", invocationID: UUID(),
            toolUseID: nil, helperPID: getpid(),
            helperStartMicroseconds: try #require(LocalPermissionFiles.processStartMicroseconds(getpid())),
            expiresAt: Date().addingTimeInterval(120), tool: "Bash", summary: "echo fixture")
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }
        func openHook() throws -> Int32 {
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(socketFD >= 0)
            do {
                let socketPath = try #require(endpoint.socket)
                var address = try #require(LocalPermissionFiles.address(socketPath))
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                try #require(connected == 0)
                var data = try JSONEncoder().encode(request)
                data.append(10)
                let sent = data.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress, $0.count, 0) }
                try #require(sent == data.count)
                try #require(fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0)
                return socketFD
            } catch {
                close(socketFD)
                throw error
            }
        }
        func receiveOutcome(_ socketFD: Int32) async throws -> LocalPermissionOutcome {
            var bytes = Data()
            try #require(
                await waitUntilEventually {
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let count = recv(socketFD, &buffer, buffer.count, 0)
                    if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
                    return bytes.contains(10)
                })
            let newline = try #require(bytes.firstIndex(of: 10))
            return try JSONDecoder().decode(LocalPermissionOutcome.self, from: Data(bytes[..<newline]))
        }
        if socketTransport {
            fd = try openHook()
        } else {
            #expect(LocalPermissionFiles.write(request, at: endpoint.file("req", id: request.invocationID)))
        }

        try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .pending })
        var authorized = true
        var authorizationCalls = 0
        let result = try coordinator.remoteResponse(
            answer: .init(identity: request.identity.companionIdentity, choice: .allow, retryID: UUID()),
            deviceID: UUID(), deviceName: "Phone",
            authorize: { body in
                authorizationCalls += 1
                // Commit, pump refresh, then the actual post-claim write.
                if stage == .claimed, authorizationCalls == 3 { authorized = false }
                guard authorized else { throw LocalAPIError.permissionDenied }
                try body()
            }, eligible: { $0 == endpoint.target }, fixture: true)
        #expect(result.receipt?.state == .recorded)
        if stage == .escaped {
            try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .delivering })
            let escaped: LocalPermissionOutcome
            if socketTransport {
                escaped = try await receiveOutcome(fd)
            } else {
                escaped = try #require(
                    LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: request.invocationID)))
            }
            #expect(escaped.identity == request.identity)
            #expect(escaped.state == .delivering)
            #expect(escaped.choice == .allow)
        }
        if stage != .claimed { authorized = false }
        let terminal: LocalPermissionState = stage == .escaped ? .unknown : .cancelled
        try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == terminal })
        let reply: LocalPermissionOutcome
        if socketTransport {
            if stage == .escaped {
                // A reconnect must see the retained unknown result, never replay the choice.
                close(fd)
                fd = -1
                fd = try openHook()
            }
            reply = try await receiveOutcome(fd)
        } else {
            try #require(
                await waitUntilEventually {
                    LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: request.invocationID))?.state
                        == terminal
                })
            reply = try #require(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: request.invocationID)))
        }
        #expect(reply.identity == request.identity)
        #expect(reply.state == terminal)
        #expect(reply.choice == nil)
    }

    @Test func decideGrantDefaultsOffAndInvalidatesLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-grant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        let fingerprint = Data(repeating: 5, count: 32)
        let phone = try access.registerCompanion(phoneName: "Phone", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        func lease() throws -> LocalAPIAuthorizationLease {
            try access.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint,
                operation: .connectionStatus
            ).get()
        }
        let old = try lease()
        #expect(!old.decisionsAllowed)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: old) {
                Issue.record("Default grant permitted work")
            }
        }
        try access.updateCompanionDecisionsAllowed(connectionID: phone.id, allowed: true)
        let granted = try lease()
        #expect(granted != old)
        #expect(granted.decisionsAllowed)
        try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {}
        try access.updateCompanionDecisionsAllowed(connectionID: phone.id, allowed: false)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {
                Issue.record("Revoked grant permitted work")
            }
        }
    }
}

// Make the directory unwritable after validation and reading, before migration saves.
private final class MigrationReadOnlyFileManager: FileManager, @unchecked Sendable {
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).lastPathComponent == "access.json" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }
        return attributes
    }
}
