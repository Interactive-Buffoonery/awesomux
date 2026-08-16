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
        let reference = setup.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = reference.flatMap { $0.isEmpty ? nil : $0 } ?? "opencode"
        guard
            let executableURL = ProcessCommandRunner.resolveExecutable(
                executable,
                searchPath: ProcessCommandRunner.defaultToolPath,
                homeDirectoryURL: homeDirectoryURL
            )
        else {
            return .failure(.executableNotFound)
        }
        do {
            return .success(try await run(executableURL, ["export", sessionID]))
        } catch {
            return .failure(.commandFailed)
        }
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
