import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Darwin
import Foundation

enum LocalAPICredentialBrokerError: Error {
    case helperUnavailable
    case helperFailed
}

struct LocalAPICredentialBroker: Sendable {
    let helperURL: URL

    init(bundle: Bundle = .main) {
        helperURL = bundle.bundleURL.appending(path: "Contents/MacOS/awesomux-agent")
    }

    @MainActor
    func register(
        in store: LocalAPIAccessStore,
        label: String,
        statusScope: LocalAPITargetScope
    ) async throws -> LocalAPIConnectionGrant {
        let pending = try store.prepareRegistration(label: label, statusScope: statusScope)
        try await runCredentialCommand(
            "store",
            profile: store.state.profile,
            connectionID: pending.connection.id,
            credential: pending.credential
        )
        do {
            try store.activateRegistration(pending)
            return pending.connection
        } catch {
            try? await runCredentialCommand(
                "delete",
                profile: store.state.profile,
                connectionID: pending.connection.id
            )
            throw error
        }
    }

    @MainActor
    func revoke(connectionID: UUID, in store: LocalAPIAccessStore) async throws {
        let profile = store.state.profile
        var persistenceError: Error?
        do {
            try store.revoke(connectionID: connectionID)
        } catch {
            persistenceError = error
        }
        try await runCredentialCommand("delete", profile: profile, connectionID: connectionID)
        if let persistenceError { throw persistenceError }
    }

    private func runCredentialCommand(
        _ command: String,
        profile: String,
        connectionID: UUID,
        credential: Data? = nil
    ) async throws {
        let helperURL = helperURL
        try await Task.detached(priority: .utility) {
            try Self.runCredentialCommandSynchronously(
                command,
                helperURL: helperURL,
                profile: profile,
                connectionID: connectionID,
                credential: credential
            )
        }.value
    }

    private static func runCredentialCommandSynchronously(
        _ command: String,
        helperURL: URL,
        profile: String,
        connectionID: UUID,
        credential: Data?
    ) throws {
        guard helperURL.isFileURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LocalAPICredentialBrokerError.helperUnavailable
        }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "credential", command,
            "--profile", profile,
            "--credential-handle", connectionID.uuidString.lowercased(),
        ]
        let input = Pipe()
        process.standardInput = credential == nil ? FileHandle.nullDevice : input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if let credential {
            try input.fileHandleForWriting.write(contentsOf: credential)
            try input.fileHandleForWriting.close()
        }
        guard finished.wait(timeout: .now() + LocalAPIContract.timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            throw LocalAPICredentialBrokerError.helperFailed
        }
        guard process.terminationStatus == 0 else { throw LocalAPICredentialBrokerError.helperFailed }
    }
}
