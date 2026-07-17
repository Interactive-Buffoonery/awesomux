import Foundation

/// Executes bridge commands assembled and shell-quoted by `AmxBackend`.
enum BridgeExecChannel {
    typealias ExecError = BoundedProcessRunner.ExecError

    static let maximumOutputByteCount = 64 * 1024

    static func run(
        command: String,
        stdin: Data?,
        timeout: DispatchTimeInterval = .seconds(15)
    ) async throws -> Data {
        try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            input: .data(stdin ?? Data()),
            maximumOutputByteCount: maximumOutputByteCount,
            timeout: timeout
        )
    }
}
