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
    /// Fully extracted lines awaiting `receive()`. A single chunk burst can
    /// carry many frames but the protocol hands them out one call at a time.
    /// Consumed through `bufferedLinesCursor`: `removeFirst()` shifts every
    /// remaining element back a slot, which made draining a K-line burst
    /// O(K²) while pinning the same lock `ingest()` needs.
    private var bufferedLines: [Data] = []
    /// Read position in `bufferedLines`; appends only ever land past it. When
    /// it catches up to the end, the backing array resets so storage does not
    /// grow with total traffic.
    private var bufferedLinesCursor = 0
    /// Violation found by the latest `ingest()`, held while its already-parsed
    /// frames finish delivering: those frames arrived legally, and dropping
    /// them would discard responses that were fully on the wire. Byte offsets
    /// past a violation are meaningless, so `receive()` surfaces this only
    /// after `bufferedLines` drains and never reads another chunk meanwhile —
    /// the same queued-drain shape as `HelperConnection.readFrame`'s
    /// `closeAfterQueuedFrames`.
    private var pendingViolation: FramingViolation?
    /// Bytes after the last newline — a partial line held for the next read.
    private var tail = Data()
    /// When the oldest byte currently in `tail` first arrived, for the
    /// partial-line deadline. `nil` exactly when `tail` is empty.
    private var tailStartedAt: Date?
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
            if let violation = takePendingViolation() {
                close()
                throw CodexAppServerError.malformedResponse(
                    "codex app-server stream framing violated: \(violation)"
                )
            }
            // bufferedLines must be fully drained before reading another
            // chunk — do not batch reads. The buffer's bound is exactly this
            // loop emptying it between reads; batching reads would silently
            // make it unbounded.
            // `availableData` blocks until bytes arrive or EOF; keep it off the
            // cooperative pool so a quiet server can't stall an executor thread.
            let handle = outputPipe.fileHandleForReading
            let chunk = await Task.detached { handle.availableData }.value

            if chunk.isEmpty {
                return takeBufferedRemainder()
            }
            ingest(chunk)
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

    // MARK: - Line buffering (synchronous helpers: NSLock is unavailable from
    // async contexts, so `receive()` never locks inline)

    /// Oldest queued line, or `nil` once drained. Internal so the seam tests
    /// can exercise burst draining directly.
    func takeBufferedLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard bufferedLinesCursor < bufferedLines.count else { return nil }
        let line = bufferedLines[bufferedLinesCursor]
        bufferedLinesCursor += 1
        if bufferedLinesCursor == bufferedLines.count {
            bufferedLines.removeAll()
            bufferedLinesCursor = 0
        }
        return line
    }

    /// The stored violation, but only once every frame parsed before it has
    /// been delivered; `nil` while frames remain queued or nothing violated.
    ///
    /// Internal so the seam tests can assert which violation survives a
    /// post-breach chunk without spawning a child and driving `receive()`.
    func takePendingViolation() -> FramingViolation? {
        lock.lock()
        defer { lock.unlock() }
        guard bufferedLinesCursor >= bufferedLines.count, let violation = pendingViolation else {
            return nil
        }
        pendingViolation = nil
        return violation
    }

    /// At EOF, return any trailing unterminated bytes as a final message, or `nil`
    /// once the buffer is fully drained.
    private func takeBufferedRemainder() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !tail.isEmpty else { return nil }
        let remainder = tail
        tail = Data()
        tailStartedAt = nil
        return remainder
    }

    /// Run the pure framing core over a fresh chunk and store the results.
    /// Frames parsed before a trailing violation queue like any other, while
    /// the violation itself waits in `pendingViolation` for `receive()` to
    /// surface it after the drain. On a violation the framing state is void:
    /// `tail` and `tailStartedAt` reset so nothing stale leaks into any later
    /// parse. Internal so the seam tests can drive chunks in directly.
    func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        // A violation is terminal: byte offsets past it are meaningless, so
        // anything still arriving cannot be reframed into a trustworthy line.
        // Dropping it keeps the queued pre-violation frames as the last thing
        // the caller sees, and stops a later chunk overwriting the pending
        // violation with its own.
        guard pendingViolation == nil else { return }
        let (lines, newTail, newTailStartedAt, violation) = Self.consume(
            chunk,
            pendingTail: tail,
            tailStartedAt: tailStartedAt,
            now: Self.monotonicNow()
        )
        bufferedLines.append(contentsOf: lines)
        if let violation {
            tail = Data()
            tailStartedAt = nil
            pendingViolation = violation
            return
        }
        tail = newTail
        tailStartedAt = newTailStartedAt
    }

    /// Monotonic clock reading for deadline math, same shape as
    /// `BridgeConnectionActor.monotonicNow`. Wall-clock `Date()` moves with
    /// NTP steps and could drag a partial-line deadline backwards;
    /// CLOCK_MONOTONIC cannot. Carried as `Date` because that is what the
    /// injected-clock API of the pure core compares.
    private static func monotonicNow() -> Date {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }

    // MARK: - Pure consume() core

    /// Hard cap on a single newline-delimited frame from `codex app-server`.
    ///
    /// Forward-looking headroom, not a bound derived from current traffic:
    /// today this path only exchanges small hook-listing and config-write
    /// payloads (`initialize`, `hooks/list`, `config/batchWrite`), but the
    /// framing layer cannot know what future app-server responses carry, and
    /// a bridge-sized cap would drop working responses rather than runaway
    /// streams if that ever grows. 16 MiB bounds memory against newline-less
    /// garbage while leaving room for far larger responses than anything
    /// shipped today. It is the steady bound, not the peak: a split line
    /// completing right at the cap transiently holds roughly 3× the cap
    /// (~48 MiB across the old tail, the combined copy, and the
    /// completed-line copy).
    static let maximumLineByteCount = 16 * 1024 * 1024

    /// How long a partial line may sit without its terminating newline while
    /// bytes are still arriving. Evaluated only inside `consume()` — that is,
    /// only when a chunk actually lands — this guard covers an actively-
    /// dribbling partial line that never completes; it cannot fire for a
    /// fully-silent child, which never gives the check another chance to run.
    /// Silence is the job of `ProcessCodexAppServerClient`'s 30 s
    /// `requestTimeout`, which races every request and force-closes the
    /// transport. Value mirrors `BridgeFrameReader.partialLineDeadline`.
    static let partialLineDeadline: TimeInterval = 10

    /// Which framing guard tripped. Either is unrecoverable protocol state —
    /// byte offsets past the violation are meaningless — so `receive()` closes
    /// the transport instead of trying to resynchronize.
    enum FramingViolation: Equatable, Sendable {
        case unterminatedLineTooLarge
        case partialLineDeadline
    }

    /// Extract complete newline-delimited frames from fresh bytes plus the
    /// held partial line. Pure: no I/O, no wall-clock reads (`now` injected,
    /// mirroring `AmxStatusFileWatcher.consume` and `BridgeFrameReader.consume`
    /// so the guards are testable without a real process).
    ///
    /// Semantics follow `BridgeFrameReader`: complete lines over
    /// `maximumLineByteCount` are dropped individually (their siblings still
    /// deliver); an *unterminated* accumulation over the cap, or a partial line
    /// older than `partialLineDeadline`, returns a violation and an empty tail.
    /// The buffer is sliced from a moving start index so one burst copies once,
    /// not once per extracted line.
    ///
    /// - Parameters:
    ///   - newBytes: Freshly read bytes from the child's stdout.
    ///   - pendingTail: Partial-line bytes carried over from the previous call.
    ///   - tailStartedAt: When `pendingTail`'s oldest byte arrived; `nil` when
    ///     the tail was empty.
    ///   - now: Injected clock reading for the deadline math.
    static func consume(
        _ newBytes: Data,
        pendingTail: Data,
        tailStartedAt: Date?,
        now: Date
    ) -> (
        lines: [Data],
        tail: Data,
        tailStartedAt: Date?,
        violation: FramingViolation?
    ) {
        var buffer = pendingTail
        if buffer.isEmpty {
            buffer = newBytes
        } else {
            buffer.append(newBytes)
        }

        guard !buffer.isEmpty else {
            return ([], Data(), nil, nil)
        }

        guard let lastNewlineIndex = buffer.lastIndex(of: 0x0A) else {
            // No newline anywhere — the whole buffer is one partial line.
            if buffer.count > maximumLineByteCount {
                return ([], Data(), nil, .unterminatedLineTooLarge)
            }
            // Deadline only gates a still-incomplete line: bytes in this call
            // that deliver the newline are processed below, never discarded.
            let startedAt = tailStartedAt ?? now
            if now.timeIntervalSince(startedAt) > partialLineDeadline {
                return ([], Data(), nil, .partialLineDeadline)
            }
            return ([], buffer, startedAt, nil)
        }

        let completeEnd = buffer.index(after: lastNewlineIndex)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        while lineStart < completeEnd {
            let newlineIndex = buffer[lineStart...].firstIndex(of: 0x0A)!
            let line = Data(buffer[lineStart..<newlineIndex])
            lineStart = buffer.index(after: newlineIndex)
            // Empty lines carry no frame; oversized-but-complete lines drop
            // like any other malformed line instead of poisoning the stream.
            guard !line.isEmpty, line.count <= maximumLineByteCount else { continue }
            lines.append(line)
        }

        let newTail = Data(buffer[completeEnd...])
        if newTail.count > maximumLineByteCount {
            return (lines, Data(), nil, .unterminatedLineTooLarge)
        }
        return (lines, newTail, newTail.isEmpty ? nil : now, nil)
    }
}
