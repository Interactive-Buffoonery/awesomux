import AwesoMuxConfig
import Foundation

/// Reads OpenCode through its public export command instead of coupling
/// awesoMux to the provider's private SQLite schema.
enum OpenCodeTranscriptExporter {
    enum ExportError: Error, Equatable {
        case executableNotFound
        case commandFailed
    }

    typealias Run = @Sendable (URL, [String]) async throws -> Data

    static let maximumOutputByteCount = 32 * 1024 * 1024

    static func export(
        sessionID: String,
        setup: AgentIntegrationSetup,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        run: Run = runProcess
    ) async -> Result<Data, ExportError> {
        guard let executableURL = resolveExecutableURL(setup: setup, homeDirectoryURL: homeDirectoryURL)
        else {
            return .failure(.executableNotFound)
        }
        do {
            return .success(try await run(executableURL, ["export", sessionID]))
        } catch {
            return .failure(.commandFailed)
        }
    }

    /// Whether the session store still holds `sessionID`.
    ///
    /// Probed through the public `session list` metadata rather than a full
    /// export, which is the difference between kilobytes and megabytes per
    /// Resume click: `export` serializes every message of the session to
    /// stdout (up to `maximumOutputByteCount` captured), while Resume only
    /// needs to know the session exists. The full list is taken without
    /// `--max-count` (that flag is "N most recent") and membership-checked
    /// here; every entry is ~270 bytes of metadata, so even thousands of
    /// sessions stay trivially under the same output cap.
    ///
    /// Fails closed on any error: an unproven log reads as missing rather
    /// than as resumable.
    static func sessionExists(
        sessionID: String,
        setup: AgentIntegrationSetup,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        run: Run = runProcess
    ) async -> Bool {
        guard let executableURL = resolveExecutableURL(setup: setup, homeDirectoryURL: homeDirectoryURL),
            let data = try? await run(executableURL, ["session", "list", "--format", "json"]),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }
        return entries.contains { $0["id"] as? String == sessionID }
    }

    private static func resolveExecutableURL(
        setup: AgentIntegrationSetup,
        homeDirectoryURL: URL
    ) -> URL? {
        let reference = setup.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = reference.flatMap { $0.isEmpty ? nil : $0 } ?? "opencode"
        return ProcessCommandRunner.resolveExecutable(
            executable,
            searchPath: ProcessCommandRunner.defaultToolPath,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    private static let runProcess: Run = { executableURL, arguments in
        try await BoundedProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            input: .data(Data()),
            maximumOutputByteCount: maximumOutputByteCount,
            timeout: .seconds(15)
        )
    }
}
