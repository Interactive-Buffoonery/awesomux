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
            deviceID: UUID(), deviceName: "Phone", workspaceIDs: [workspace],
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
        #expect(old.decideWorkspaceIDs == nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: old) {
                Issue.record("Default grant permitted work")
            }
        }
        let workspace = UUID()
        try access.updateCompanionDecideWorkspaces(connectionID: phone.id, workspaceIDs: [workspace])
        let granted = try lease()
        #expect(granted != old)
        #expect(granted.decideWorkspaceIDs == [workspace])
        try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {}
        try access.updateCompanionDecideWorkspaces(connectionID: phone.id, workspaceIDs: nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {
                Issue.record("Revoked grant permitted work")
            }
        }
    }
}
