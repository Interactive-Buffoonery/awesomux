import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import Foundation
import Network
import os

extension CompanionTerminalStream.EndReason: @retroactive Error {}

/// Bridges callback APIs without relying on a cancellation callback from Network.
/// Late callbacks lose the race and cannot resume a continuation twice.
final class CompanionNetworkOperation<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let outcome = state.withLock { state -> (Bool, CheckedContinuation<Value, Error>?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        outcome.1?.resume(with: result)
        return outcome.0
    }

    func wait(
        cancel: @escaping @Sendable () -> Void = {}, isolation: isolated (any Actor)? = #isolation, start: () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = state.withLock { state -> Result<Value, Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) } else { start() }
            }
        } onCancel: {
            if self.resolve(.failure(CancellationError())) { cancel() }
        }
    }
}

/// Translates one typed zmx attachment into ADR-0040 frames. Device input
/// crosses only as validated UserBatch or TakeOver operations.
enum CompanionTerminalWatchRelay {
    typealias Stream = CompanionTerminalStream

    /// Watch-only zmx wire (vendor/zmx `ipc.zig`, MIT): an 8-byte header with the
    /// tag at byte 0 and a little-endian u32 length at bytes 1...4.
    enum ZmxTag: UInt8 {
        case output = 1
        case sessionEnd = 14
        case attachRole = 26
        case attachAccepted = 27
        case authority = 28
        case userBatch = 29
        case takeOver = 31
    }

    struct ZmxMessage: Equatable {
        let tag: UInt8
        let payload: Data
    }

    struct Authority {
        let leader: UInt64
        let grid: Stream.Grid

        init?(_ message: ZmxMessage) {
            guard message.tag == ZmxTag.authority.rawValue, message.payload.count == 20 else { return nil }
            leader = message.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            let rows = message.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt16.self) }.littleEndian
            let cols = message.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 18, as: UInt16.self) }.littleEndian
            grid = .init(rows: Int(rows), cols: Int(cols))
        }
    }

    static let zmxHeaderBytes = 8
    static let acceptTimeout: Duration = .seconds(1)
    static let writeTimeout: Duration = .seconds(Stream.idleTimeoutSeconds)
    static let snapshotDeliveryTimeout: Duration = .seconds(Stream.idleTimeoutSeconds)
    static let maximumOverflowsPerMinute = 3
    static let finalWriteTimeout: Duration = .seconds(1)

    static func phoneTCPOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Int(Stream.heartbeatSeconds)
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        // Local send completion does not prove peer receipt. This bounds TCP's
        // unacknowledged retransmissions even while heartbeats enter its buffer.
        tcp.connectionDropTime = Int(Stream.idleTimeoutSeconds)
        return tcp
    }

    static func zmxMessage(_ tag: ZmxTag, _ payload: Data) -> Data {
        var data = Data(count: zmxHeaderBytes)
        data[0] = tag.rawValue
        let length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: length) { data.replaceSubrange(1..<5, with: $0) }
        return data + payload
    }

    static func attachRequest(_ grid: Stream.Grid, role: Stream.Role = .watch) -> Data {
        zmxMessage(.attachRole, Data([1, role == .interactive ? 2 : 1]) + gridPayload(grid))
    }

    static func gridPayload(_ grid: Stream.Grid) -> Data {
        var payload = Data()
        for value in [UInt16(grid.rows).littleEndian, UInt16(grid.cols).littleEndian] {
            withUnsafeBytes(of: value) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    struct ZmxParser {
        enum Failure: Error { case messageTooLarge }
        private var buffer = Data()

        mutating func feed(_ data: Data) throws -> [ZmxMessage] {
            buffer.append(data)
            var messages: [ZmxMessage] = []
            while buffer.count >= zmxHeaderBytes {
                let length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }.littleEndian)
                guard length <= Stream.maximumSnapshotBytes else { throw Failure.messageTooLarge }
                guard buffer.count >= zmxHeaderBytes + length else { break }
                messages.append(ZmxMessage(tag: buffer[0], payload: buffer.subdata(in: zmxHeaderBytes..<zmxHeaderBytes + length)))
                buffer.removeSubrange(0..<zmxHeaderBytes + length)
            }
            return messages
        }
    }

    /// Pure zmx -> stream translation for one attach generation.
    struct Translator {
        enum Phase { case awaitingAccept, awaitingSnapshot, streaming }
        enum Result: Equatable {
            case frames([Stream.Frame])
            case end(Stream.EndReason)
        }

        let paneID: UUID
        let targetVersion: UUID
        private(set) var phase: Phase = .awaitingAccept
        private(set) var sequence: UInt64 = 0
        private(set) var grid: Stream.Grid
        private(set) var leader: String?

        init(paneID: UUID, targetVersion: UUID, grid: Stream.Grid) {
            self.paneID = paneID
            self.targetVersion = targetVersion
            self.grid = grid
        }

        var snapshotConstructed: Bool { phase == .streaming }

        mutating func translate(_ message: ZmxMessage) -> Result {
            switch ZmxTag(rawValue: message.tag) {
            case .attachAccepted:
                guard phase == .awaitingAccept, message.payload.count == 16 else { return .frames([]) }
                phase = .awaitingSnapshot
                return .frames([])
            case .authority:
                guard let authority = Authority(message) else { return .frames([]) }
                leader = authority.leader == 0 ? nil : String(authority.leader)
                grid = authority.grid
                return .frames(phase == .streaming ? [.leader(.init(leader: leader)), .grid(grid)] : [])
            case .output:
                switch phase {
                case .awaitingAccept:
                    return .frames([])
                case .awaitingSnapshot:
                    phase = .streaming
                    let begin = Stream.SnapshotBegin(
                        paneID: paneID.uuidString.lowercased(), targetVersion: targetVersion.uuidString.lowercased(),
                        grid: grid, leader: leader, scrollbackBound: Stream.maximumSnapshotBytes)
                    return .frames(
                        [.snapshotBegin(begin)] + chunks(message.payload) { .snapshot(sequence: $0, bytes: $1) }
                            + [.snapshotEnd(.init(bytes: message.payload.count))])
                case .streaming:
                    return .frames(chunks(message.payload) { .output(sequence: $0, bytes: $1) })
                }
            case .sessionEnd:
                return .end(.sessionEnded)
            case .attachRole, .userBatch, .takeOver, .none:
                return .frames([])
            }
        }

        private mutating func chunks(_ bytes: Data, _ make: (UInt64, Data) -> Stream.Frame) -> [Stream.Frame] {
            stride(from: 0, to: bytes.count, by: Stream.maximumDataBytes).map { offset in
                defer { sequence += 1 }
                return make(sequence, bytes.subdata(in: offset..<min(offset + Stream.maximumDataBytes, bytes.count)))
            }
        }
    }

    struct QueuedFrame: Equatable, Sendable {
        let generation: UInt32
        let data: Data
        let snapshotEnd: Bool
    }

    /// Frames live only in this byte-bounded queue. The coalesced wake stream
    /// carries no terminal bytes and cannot retain an abandoned generation.
    final class Buffer: Sendable {
        private struct State {
            var generation: UInt32 = 0
            var frames: [QueuedFrame] = []
            var inFlight: QueuedFrame?
            var pendingBytes = 0
            var snapshotDelivered = false
            var snapshotStarted: ContinuousClock.Instant?
            var resync = false
            var overflows: [ContinuousClock.Instant] = []
            var reason: Stream.EndReason?
            var sourceEnd: Stream.EndReason?
            var tick = false
            var tasks: [Task<Void, Never>] = []
            var activeWriter: Task<WriteFailure?, Never>?
            var drainWaiters: [UUID: CompanionNetworkOperation<Void>] = [:]
            var capacityWaiters: [UUID: CompanionNetworkOperation<Void>] = [:]
        }

        let diagnostics: CompanionDiagnostics
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let maximumPendingBytes: Int
        private let now: @Sendable () -> ContinuousClock.Instant
        let wakes: AsyncStream<Void>
        private let wake: AsyncStream<Void>.Continuation

        init(
            maximumPendingBytes: Int = Stream.maximumPendingBytes,
            diagnostics: CompanionDiagnostics = CompanionDiagnostics(),
            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
        ) {
            self.diagnostics = diagnostics
            self.maximumPendingBytes = maximumPendingBytes
            self.now = now
            (wakes, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        var pendingBytes: Int { state.withLock { $0.pendingBytes } }
        var generation: UInt32 { state.withLock { $0.generation } }
        var snapshotDelivered: Bool { state.withLock { $0.snapshotDelivered } }
        var endReason: Stream.EndReason? {
            state.withLock { $0.reason ?? ($0.frames.isEmpty && $0.inFlight == nil ? $0.sourceEnd : nil) }
        }

        func acceptsInput(generation: UInt32) -> Bool {
            state.withLock { $0.generation == generation && !$0.resync && $0.reason == nil && $0.sourceEnd == nil }
        }

        func needsResync(generation: UInt32) -> Bool {
            state.withLock { $0.generation == generation && $0.resync && $0.reason == nil }
        }

        @MainActor
        func forwardInput(generation: UInt32, submit: @MainActor @Sendable () throws -> Void) throws {
            try state.withLock { state in
                guard state.generation == generation, !state.resync, state.reason == nil, state.sourceEnd == nil
                else { throw CancellationError() }
                try MainActor.assumeIsolated { try submit() }
            }
        }

        func install(_ tasks: [Task<Void, Never>]) {
            let stopped = state.withLock { state in
                state.tasks = tasks
                return state.reason != nil
            }
            if stopped { tasks.forEach { $0.cancel() } }
        }

        func installWriter(_ writer: Task<WriteFailure?, Never>) {
            let stopped = state.withLock { state in
                state.activeWriter = writer
                return state.reason != nil
            }
            if stopped { writer.cancel() }
        }

        func clearWriter() { state.withLock { $0.activeWriter = nil } }

        func beginGeneration() -> UInt32? {
            state.withLock { state in
                guard state.reason == nil, state.inFlight == nil, state.frames.isEmpty else { return nil }
                state.generation += 1
                state.snapshotDelivered = false
                state.snapshotStarted = nil
                state.resync = false
                return state.generation
            }
        }

        func enqueue(_ frame: Stream.Frame, generation: UInt32) -> Step {
            guard let queued = encode(frame, generation: generation) else { return .end(.protocolError) }
            return enqueue(queued)
        }

        // Only snapshot production waits for capacity, on this stream's own
        // daemon socket. Live output retains the discard-and-resync policy.
        func enqueueSnapshot(_ frame: Stream.Frame, generation: UInt32) async throws -> Step {
            guard let queued = encode(frame, generation: generation) else { return .end(.protocolError) }
            let started = now()
            state.withLock { state in
                if state.generation == generation, state.snapshotStarted == nil {
                    state.snapshotStarted = started
                }
            }
            while true {
                try Task.checkCancellation()
                let id = UUID()
                let operation = CompanionNetworkOperation<Void>()
                defer { _ = state.withLock { $0.capacityWaiters.removeValue(forKey: id) } }
                let canEnqueue = state.withLock { state in
                    if state.reason != nil || state.generation != generation || state.resync
                        || queued.data.count > maximumPendingBytes
                        || state.pendingBytes + queued.data.count <= maximumPendingBytes
                    {
                        return true
                    }
                    state.capacityWaiters[id] = operation
                    return false
                }
                if canEnqueue { return enqueue(queued) }
                try await operation.wait {}
            }
        }

        func snapshotTimeRemaining(now: ContinuousClock.Instant) -> Duration? {
            state.withLock { state in
                guard !state.snapshotDelivered, let start = state.snapshotStarted else { return nil }
                return snapshotDeliveryTimeout - (now - start)
            }
        }

        func expireSnapshot(now: ContinuousClock.Instant) {
            if let remaining = snapshotTimeRemaining(now: now), remaining <= .zero {
                stop(.overflow)
            }
        }

        private func encode(_ frame: Stream.Frame, generation: UInt32) -> QueuedFrame? {
            guard let data = try? Stream.encode(frame, generation: generation) else {
                stop(.protocolError)
                return nil
            }
            let snapshotEnd: Bool
            if case .snapshotEnd = frame { snapshotEnd = true } else { snapshotEnd = false }
            return QueuedFrame(generation: generation, data: data, snapshotEnd: snapshotEnd)
        }

        private func enqueue(_ frame: QueuedFrame) -> Step {
            let result: Step = state.withLock { state in
                if let reason = state.reason { return .end(reason) }
                guard state.generation == frame.generation, !state.resync else { return .overflow }
                guard state.pendingBytes + frame.data.count <= maximumPendingBytes else {
                    state.frames.removeAll(keepingCapacity: false)
                    state.pendingBytes = state.inFlight?.data.count ?? 0
                    state.resync = true
                    let now = ContinuousClock.now
                    state.overflows = state.overflows.filter { now - $0 < .seconds(60) } + [now]
                    guard state.snapshotDelivered, state.overflows.count <= maximumOverflowsPerMinute else {
                        return .end(.overflow)
                    }
                    return .overflow
                }
                state.frames.append(frame)
                state.pendingBytes += frame.data.count
                return .continue
            }
            if case .end(let reason) = result { stop(reason) }
            wake.yield(())
            return result
        }

        func takeFrame() -> QueuedFrame? {
            state.withLock { state in
                guard state.reason == nil, state.inFlight == nil, !state.frames.isEmpty else { return nil }
                let frame = state.frames.removeFirst()
                state.inFlight = frame
                return frame
            }
        }

        func takeHeartbeat() -> QueuedFrame? {
            state.withLock { state in
                guard state.reason == nil, state.snapshotDelivered, !state.resync, state.inFlight == nil, state.frames.isEmpty,
                    let data = try? Stream.encode(.heartbeat, generation: state.generation)
                else { return nil }
                let frame = QueuedFrame(generation: state.generation, data: data, snapshotEnd: false)
                state.inFlight = frame
                state.pendingBytes += data.count
                return frame
            }
        }

        func didWrite(_ frame: QueuedFrame) {
            let waiters = state.withLock { state -> [CompanionNetworkOperation<Void>] in
                guard state.inFlight == frame else { return [] }
                state.pendingBytes -= frame.data.count
                state.inFlight = nil
                if frame.snapshotEnd, frame.generation == state.generation { state.snapshotDelivered = true }
                let waiters = Array(state.drainWaiters.values) + Array(state.capacityWaiters.values)
                state.drainWaiters.removeAll()
                state.capacityWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resolve(.success(())) }
            wake.yield(())
        }

        func waitForDrain() async throws {
            let id = UUID()
            let operation = CompanionNetworkOperation<Void>()
            defer { _ = state.withLock { $0.drainWaiters.removeValue(forKey: id) } }
            let drained = state.withLock { state in
                if state.inFlight == nil { return true }
                state.drainWaiters[id] = operation
                return false
            }
            if !drained { try await operation.wait {} }
            try Task.checkCancellation()
        }

        func tick() {
            state.withLock { $0.tick = true }
            wake.yield(())
        }

        func takeTick() -> Bool {
            state.withLock { state in
                defer { state.tick = false }
                return state.tick
            }
        }

        func finish(_ reason: Stream.EndReason) {
            diagnostics.close(origin: "daemon", phase: "producer_end", reason: reason.rawValue)
            state.withLock { $0.sourceEnd = reason }
            wake.yield(())
        }

        func stop(_ reason: Stream.EndReason) {
            diagnostics.close(origin: "relay", phase: "stop", reason: reason.rawValue)
            let (tasks, writer, waiters) = state.withLock { state in
                if state.reason == nil { state.reason = reason }
                state.frames.removeAll(keepingCapacity: false)
                state.pendingBytes = state.inFlight?.data.count ?? 0
                let waiters = Array(state.capacityWaiters.values)
                state.capacityWaiters.removeAll()
                return (state.tasks, state.activeWriter, waiters)
            }
            waiters.forEach { $0.resolve(.success(())) }
            tasks.forEach { $0.cancel() }
            writer?.cancel()
            wake.yield(())
        }
    }

    /// Cancellation of the producer closes zmx. Cancellation of the phone reader
    /// abandons its continuation only; TLS stays writable for a final end frame.
    static func run(
        socketPath: String,
        paneID: UUID,
        targetVersion: UUID,
        grid: Stream.Grid,
        role: Stream.Role = .watch,
        validateInput: @escaping @MainActor @Sendable () throws -> Void = {},
        commitInput: @escaping @MainActor @Sendable (@MainActor @Sendable () -> Void) throws -> Void = { $0() },
        attachmentChanged: @escaping @MainActor @Sendable (UInt64?) -> Void = { _ in },
        buffer: Buffer,
        phoneFrames: @escaping @Sendable () async throws -> Data,
        send: @escaping @MainActor @Sendable (Data) async throws -> Void,
        sendEnd: @escaping @MainActor @Sendable (Data) async throws -> Void,
        delay: @escaping CompanionDelay,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        produce: (@Sendable (Buffer) async -> Void)? = nil
    ) async -> Stream.EndReason {
        let input = await InputForwarder(role: role, grid: grid, buffer: buffer, validate: validateInput)
        return await withTaskCancellationHandler {
            let producer = Task {
                if let produce {
                    await produce(buffer)
                } else {
                    buffer.finish(
                        await attachLoop(
                            socketPath: socketPath, paneID: paneID, targetVersion: targetVersion,
                            grid: grid, role: role, input: input, commitInput: commitInput,
                            attachmentChanged: attachmentChanged, buffer: buffer, delay: delay))
                }
            }
            let timer = Task {
                while !Task.isCancelled {
                    guard (try? await delay(.seconds(5))) != nil, !Task.isCancelled else { return }
                    buffer.expireSnapshot(now: now())
                    buffer.tick()
                }
            }
            let reader = Task {
                while !Task.isCancelled {
                    do {
                        let data = try await phoneFrames()
                        try await input.receive(data)
                    } catch LocalAPIError.requestTooLarge {
                        buffer.stop(.protocolError)
                        return
                    } catch let reason as Stream.EndReason {
                        buffer.stop(reason)
                        return
                    } catch {
                        if !Task.isCancelled {
                            buffer.diagnostics.close(origin: "phone", phase: "receive", reason: CompanionDiagnostics.reason(error))
                            buffer.stop(.closed)
                        }
                        return
                    }
                }
            }
            buffer.install([producer, timer, reader])
            var lastSend = now()
            var reason: Stream.EndReason = .closed
            var atFrameBoundary = true
            loop: for await _ in buffer.wakes {
                while let frame = buffer.takeFrame() {
                    buffer.expireSnapshot(now: now())
                    if let end = buffer.endReason { reason = end; break loop }
                    if let failure = await writeBuffered(frame.data, buffer: buffer, send: send, delay: delay, now: now) {
                        // A failed write may have sent part of the frame. Never
                        // append end bytes to an indeterminate frame boundary.
                        buffer.diagnostics.close(origin: "transport", phase: "write", reason: failure.reason.rawValue)
                        atFrameBoundary = failure.atFrameBoundary
                        reason = buffer.endReason ?? failure.reason
                        break loop
                    }
                    buffer.diagnostics.wrote(bytes: frame.data.count)
                    buffer.didWrite(frame)
                    lastSend = now()
                }
                if let end = buffer.endReason { reason = end; break }
                let idle = now() - lastSend
                let tick = buffer.takeTick()
                if tick, idle >= .seconds(Stream.idleTimeoutSeconds), !buffer.snapshotDelivered {
                    reason = .paneUnavailable
                    break
                }
                if tick, idle >= .seconds(Stream.heartbeatSeconds),
                    let heartbeat = buffer.takeHeartbeat()
                {
                    if let failure = await writeBuffered(heartbeat.data, buffer: buffer, send: send, delay: delay, now: now) {
                        buffer.diagnostics.close(origin: "transport", phase: "write", reason: failure.reason.rawValue)
                        atFrameBoundary = failure.atFrameBoundary
                        reason = buffer.endReason ?? failure.reason
                        break
                    }
                    buffer.diagnostics.wrote(bytes: heartbeat.data.count, heartbeat: true)
                    buffer.didWrite(heartbeat)
                    lastSend = now()
                }
            }
            reason = buffer.endReason ?? reason
            buffer.diagnostics.close(origin: "relay", phase: "end", reason: reason.rawValue)
            buffer.stop(reason)
            await producer.value
            await reader.value
            await timer.value
            if atFrameBoundary, let end = try? Stream.encode(.end(.init(reason: reason)), generation: buffer.generation) {
                // A cancelled parent must still be able to send the final reason.
                let finalReason = reason
                await Task {
                    let failure = await write(
                        end, send: sendEnd, delay: delay, timeout: finalWriteTimeout, diagnostics: buffer.diagnostics)
                    CompanionDiagnostics.watch.notice(
                        "final_end watch_id=\(buffer.diagnostics.id, privacy: .public) sent=\(failure == nil) reason=\(finalReason.rawValue, privacy: .public)"
                    )
                }.value
            } else {
                CompanionDiagnostics.watch.notice(
                    "final_end_skipped watch_id=\(buffer.diagnostics.id, privacy: .public) reason=partial_frame_or_encoding")
            }
            buffer.diagnostics.end(generation: buffer.generation, pendingBytes: buffer.pendingBytes)
            return reason
        } onCancel: {
            buffer.diagnostics.close(origin: "task", phase: "cancel", reason: "cancelled")
            buffer.stop(.closed)
        }
    }

    struct WriteFailure: Error, Equatable {
        let reason: Stream.EndReason
        let atFrameBoundary: Bool
    }

    struct ChunkWriteFailure: Error {
        let underlying: any Error
        let atFrameBoundary: Bool
    }

    /// Validation is called inside the submission callback, after any async
    /// suspension and immediately before bytes enter Network.framework.
    @MainActor
    static func writeChunks(
        _ frame: Data,
        diagnostics: CompanionDiagnostics? = nil,
        validate: @escaping @MainActor () throws -> Void,
        submit: @MainActor (Data, @escaping @MainActor () throws -> Void) async throws -> Void,
        close: @MainActor () -> Void
    ) async throws {
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 16 * 1024, frame.count)
            var submitted = false
            do {
                try await submit(frame.subdata(in: offset..<end)) {
                    try validate()
                    submitted = true
                }
            } catch {
                diagnostics?.close(origin: "transport", phase: "write", reason: CompanionDiagnostics.reason(error))
                let atFrameBoundary = offset == 0 && !submitted && !(error is CancellationError)
                if !atFrameBoundary { close() }
                throw ChunkWriteFailure(underlying: error, atFrameBoundary: atFrameBoundary)
            }
            offset = end
        }
    }

    private static func writeBuffered(
        _ data: Data, buffer: Buffer, send: @escaping @MainActor @Sendable (Data) async throws -> Void,
        delay: @escaping CompanionDelay, now: @escaping @Sendable () -> ContinuousClock.Instant
    ) async -> WriteFailure? {
        let remaining = buffer.snapshotTimeRemaining(now: now())
        let writer = Task {
            await write(
                data, send: send, delay: delay, timeout: min(writeTimeout, remaining ?? writeTimeout),
                timeoutReason: remaining == nil ? .closed : .overflow, diagnostics: buffer.diagnostics)
        }
        buffer.installWriter(writer)
        defer { buffer.clearWriter() }
        return await withTaskCancellationHandler {
            await writer.value
        } onCancel: {
            writer.cancel()
        }
    }

    /// Send callbacks must be cancellation-aware so the losing timeout task can
    /// finish. Cancelling an in-flight send closes its possibly partial frame.
    static func write(
        _ data: Data, send: @escaping @MainActor @Sendable (Data) async throws -> Void,
        delay: @escaping CompanionDelay, timeout: Duration = writeTimeout, timeoutReason: Stream.EndReason = .closed,
        diagnostics: CompanionDiagnostics? = nil
    ) async -> WriteFailure? {
        await withTaskGroup(of: WriteFailure?.self) { group in
            group.addTask {
                do {
                    try await send(data)
                    return nil
                } catch let failure as WriteFailure {
                    return failure
                } catch LocalAPIError.permissionDenied {
                    return WriteFailure(reason: .revoked, atFrameBoundary: true)
                } catch let error as Stream.EndReason {
                    return WriteFailure(reason: error, atFrameBoundary: true)
                } catch {
                    return WriteFailure(reason: .closed, atFrameBoundary: false)
                }
            }
            group.addTask {
                try? await delay(timeout)
                if !Task.isCancelled {
                    diagnostics?.close(origin: "transport", phase: "write_timeout", reason: timeoutReason.rawValue)
                    CompanionDiagnostics.transport.notice(
                        "write_timeout watch_id=\(diagnostics?.id.uuidString ?? "none", privacy: .public) limit_ms=\(CompanionDiagnostics.milliseconds(timeout))"
                    )
                }
                return WriteFailure(reason: timeoutReason, atFrameBoundary: false)
            }
            let first = await group.next() ?? WriteFailure(reason: .closed, atFrameBoundary: false)
            group.cancelAll()
            return first
        }
    }

    private static func attachLoop(
        socketPath: String, paneID: UUID, targetVersion: UUID, grid: Stream.Grid,
        role: Stream.Role, input: InputForwarder,
        commitInput: @escaping @MainActor @Sendable (@MainActor @Sendable () -> Void) throws -> Void,
        attachmentChanged: @escaping @MainActor @Sendable (UInt64?) -> Void,
        buffer: Buffer, delay: @escaping CompanionDelay
    ) async -> Stream.EndReason {
        while !Task.isCancelled {
            guard let generation = buffer.beginGeneration() else { return buffer.endReason ?? .closed }
            var translator = Translator(paneID: paneID, targetVersion: targetVersion, grid: grid)
            let outcome = await attach(
                socketPath: socketPath, grid: grid, role: role, delay: delay,
                accepted: { connection, payload in
                    guard payload.count == 16 else { return }
                    let id = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
                    let revision = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }.littleEndian
                    input.install(generation: generation, id: id, revision: revision, resync: { connection.cancel() }) { data, validate in
                        try await send(data, connection: connection) { submit in
                            try validate()
                            try buffer.forwardInput(generation: generation) {
                                try commitInput(submit)
                            }
                        }
                    }
                    attachmentChanged(id)
                }
            ) { message in
                switch translator.translate(message) {
                case .end(let reason):
                    return .end(reason)
                case .frames(let frames):
                    for frame in frames {
                        let step: Step
                        switch frame {
                        case .snapshotBegin, .snapshot, .snapshotEnd:
                            do { step = try await buffer.enqueueSnapshot(frame, generation: generation) } catch { return .end(.closed) }
                        default:
                            step = buffer.enqueue(frame, generation: generation)
                        }
                        if case .continue = step { continue }
                        return step
                    }
                    return .continue
                }
            }
            await input.detach(generation: generation)
            await attachmentChanged(nil)
            switch buffer.needsResync(generation: generation) ? .overflow : outcome {
            case .end(let reason):
                return reason
            case .overflow, .continue:
                // attach's defer has already detached zmx. Do not open the next
                // generation until the one outstanding phone write has drained.
                do { try await buffer.waitForDrain() } catch { return .closed }
            }
        }
        return .closed
    }

    enum Step: Equatable, Sendable { case `continue`, overflow, end(Stream.EndReason) }

    /// One startup deadline covers both readiness and the attach submission.
    /// Both callbacks must abandon their waits when the losing task is cancelled.
    static func prepareAttach(
        ready: @escaping @Sendable () async throws -> Void,
        sendAttach: @escaping @Sendable () async throws -> Void,
        cancel: @escaping @Sendable () -> Void,
        delay: @escaping CompanionDelay
    ) async -> Step {
        await withTaskGroup(of: Step.self) { group in
            group.addTask {
                do {
                    try await ready()
                    try Task.checkCancellation()
                    try await sendAttach()
                    return .continue
                } catch {
                    cancel()
                    return .end(.paneUnavailable)
                }
            }
            group.addTask {
                do { try await delay(acceptTimeout) } catch { return .end(.paneUnavailable) }
                cancel()
                return .end(.paneUnavailable)
            }
            let first = await group.next() ?? .end(.paneUnavailable)
            group.cancelAll()
            return first
        }
    }

    static func attach(
        socketPath: String, grid: Stream.Grid, role: Stream.Role = .watch, delay: @escaping CompanionDelay,
        isolation: isolated (any Actor)? = #isolation,
        accepted acceptedCallback: @escaping @MainActor @Sendable (NWConnection, Data) -> Void = { _, _ in },
        handle: (ZmxMessage) async -> Step
    ) async -> Step {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        let prepared = await prepareAttach(
            ready: {
                let ready = CompanionNetworkOperation<Void>()
                try await ready.wait(cancel: { connection.cancel() }) {
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: ready.resolve(.success(()))
                        case .failed(let error): ready.resolve(.failure(error))
                        case .cancelled: ready.resolve(.failure(CancellationError()))
                        default: break
                        }
                    }
                    connection.start(queue: DispatchQueue(label: "awesomux.companion.zmx-watch", qos: .utility))
                }
            },
            sendAttach: {
                try await send(attachRequest(grid, role: role), connection: connection)
            }, cancel: { connection.cancel() }, delay: delay)
        guard prepared == .continue else { return prepared }
        var parser = ZmxParser()
        var accepted = false
        while !Task.isCancelled {
            guard let data = await receive(connection, timeout: accepted ? nil : acceptTimeout, delay: delay) else {
                return .end(accepted ? .sessionEnded : .paneUnavailable)
            }
            guard let messages = try? parser.feed(data) else { return .end(.overflow) }
            for message in messages {
                if message.tag == ZmxTag.attachAccepted.rawValue {
                    guard message.payload.count == 16, !accepted else { return .end(.protocolError) }
                    accepted = true
                    await acceptedCallback(connection, message.payload)
                }
                let step = await handle(message)
                if case .continue = step { continue }
                return step
            }
        }
        return .end(.closed)
    }

    @MainActor
    private static func send(
        _ data: Data, connection: NWConnection,
        authorize: @MainActor (@MainActor @Sendable () -> Void) throws -> Void = { $0() }
    ) async throws {
        let operation = CompanionNetworkOperation<Void>()
        try await operation.wait(cancel: { connection.cancel() }) {
            do {
                try authorize {
                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error { operation.resolve(.failure(error)) } else { operation.resolve(.success(())) }
                        })
                }
            } catch { operation.resolve(.failure(error)) }
        }
    }

    private static func receive(_ connection: NWConnection, timeout: Duration?, delay: @escaping CompanionDelay) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                let operation = CompanionNetworkOperation<Data>()
                return try? await operation.wait(cancel: { connection.cancel() }) {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: Stream.maximumDataBytes) { data, _, complete, error in
                        if let error {
                            CompanionDiagnostics.networkError(error, phase: "daemon_receive")
                            operation.resolve(.failure(error))
                        } else if let data, !data.isEmpty {
                            operation.resolve(.success(data))
                        } else {
                            CompanionDiagnostics.transport.notice("daemon_eof complete=\(complete)")
                            operation.resolve(.failure(CancellationError()))
                        }
                    }
                }
            }
            if let timeout {
                group.addTask {
                    try? await delay(timeout)
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
