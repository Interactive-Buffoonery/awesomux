import Foundation
@testable import awesoMux

// MARK: - StubCodexAppServerClient

/// `CodexAppServerClient` test double for consumers (P4/P5). Returns a canned
/// `hooks/list` payload (or a canned failure) and records every
/// `configBatchWrite` call for assertion.
final class StubCodexAppServerClient: CodexAppServerClient, @unchecked Sendable {
    struct BatchWriteCall: Equatable, Sendable {
        var writes: [CodexConfigWrite]
        var reloadUserConfig: Bool
    }

    private let lock = NSLock()
    private var hooksListOutcome: Result<[HookEntry], CodexAppServerError> = .success([])
    private var recordedWrites: [BatchWriteCall] = []
    private var batchWriteFailure: CodexAppServerError?
    private var closeCount = 0

    var batchWriteCalls: [BatchWriteCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCount
    }

    func setHooksList(_ entries: [HookEntry]) {
        lock.lock()
        hooksListOutcome = .success(entries)
        lock.unlock()
    }

    func setHooksListFailure(_ error: CodexAppServerError) {
        lock.lock()
        hooksListOutcome = .failure(error)
        lock.unlock()
    }

    func setBatchWriteFailure(_ error: CodexAppServerError) {
        lock.lock()
        batchWriteFailure = error
        lock.unlock()
    }

    func hooksList() async throws -> [HookEntry] {
        let outcome = lock.withLock { hooksListOutcome }
        return try outcome.get()
    }

    func configBatchWrite(_ writes: [CodexConfigWrite], reloadUserConfig: Bool) async throws {
        let failure = lock.withLock { () -> CodexAppServerError? in
            recordedWrites.append(BatchWriteCall(writes: writes, reloadUserConfig: reloadUserConfig))
            return batchWriteFailure
        }
        if let failure {
            throw failure
        }
    }

    func close() {
        lock.withLock { closeCount += 1 }
    }
}
