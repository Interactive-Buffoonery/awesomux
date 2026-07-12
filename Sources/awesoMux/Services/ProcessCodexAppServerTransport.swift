import Foundation

// MARK: - ProcessCodexAppServerTransport

/// Real `CodexAppServerTransport`: spawns `codex app-server` and frames JSON-RPC
/// over its stdio as newline-delimited JSON. `CODEX_HOME` is threaded into the
/// child so the session sees the same config home every other Codex call targets
/// (contract §2.1). Owns the process lifetime: closed explicitly or on `deinit`.
final class ProcessCodexAppServerTransport: CodexAppServerTransport, @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe() // our writes → child stdin
    private let outputPipe = Pipe() // child stdout → our reads

    private let lock = NSLock()
    private var readBuffer = Data()
    private var didClose = false

    init(
        executable: String,
        codexHome: String,
        arguments: [String] = ["app-server"],
        defaultPath: String = ProcessCommandRunner.defaultToolPath
    ) throws {
        // Resolve against PATH so a bare `codex` (the default binary) works, matching
        // the CLI spawn path in ProcessCommandRunner. An absolute/relative path is
        // tilde-expanded and checked directly. No PATH resolution here would fail
        // every machine that installs codex outside the hard-coded default.
        guard let url = ProcessCommandRunner.resolveExecutable(
            executable,
            searchPath: defaultPath,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            throw CodexAppServerError.appServerUnavailable(
                reason: "codex executable not found at \(executable)"
            )
        }

        process.executableURL = url
        process.arguments = arguments
        // Minimal env + the one key Codex must see; never inherit the host env.
        process.environment = [
            "PATH": defaultPath,
            "CODEX_HOME": codexHome
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.appServerUnavailable(reason: error.localizedDescription)
        }
    }

    deinit {
        close()
    }

    func send(_ message: Data) async throws {
        var framed = message
        framed.append(0x0A) // newline frame
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: framed)
        } catch {
            throw CodexAppServerError.connectionClosed
        }
    }

    func receive() async throws -> Data? {
        while true {
            if let line = takeBufferedLine() {
                return line
            }
            // `availableData` blocks until bytes arrive or EOF; keep it off the
            // cooperative pool so a quiet server can't stall an executor thread.
            let handle = outputPipe.fileHandleForReading
            let chunk = await Task.detached { handle.availableData }.value
            if chunk.isEmpty {
                return takeBufferedRemainder()
            }
            appendToBuffer(chunk)
        }
    }

    func close() {
        lock.lock()
        let alreadyClosed = didClose
        didClose = true
        lock.unlock()
        guard !alreadyClosed else { return }

        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Line buffering

    private func appendToBuffer(_ chunk: Data) {
        lock.lock()
        readBuffer.append(chunk)
        lock.unlock()
    }

    private func takeBufferedLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let newlineIndex = readBuffer.firstIndex(of: 0x0A) else {
            return nil
        }
        let line = readBuffer[readBuffer.startIndex..<newlineIndex]
        readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
        return Data(line)
    }

    /// At EOF, return any trailing unterminated bytes as a final message, or `nil`
    /// once the buffer is fully drained.
    private func takeBufferedRemainder() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !readBuffer.isEmpty else { return nil }
        let remainder = readBuffer
        readBuffer.removeAll()
        return remainder
    }
}
