import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing
import os

@testable import awesoMux

@MainActor
@Suite("Companion terminal watch")
struct CompanionTerminalWatchTests {
    typealias Relay = CompanionTerminalWatchRelay
    typealias Stream = CompanionTerminalStream

    private let fingerprint = Data(repeating: 5, count: 32)

    private func request(_ operation: String, extra: [String: Any] = [:]) throws -> LocalAPIRequest {
        var object: [String: Any] = [
            "schemaVersion": 1, "requestID": UUID().uuidString, "profile": "development", "operation": operation,
        ]
        object.merge(extra) { _, new in new }
        return try LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func watchRequestNeedsPaneAndTargetAndOtherOperationsRejectThem() throws {
        let pane = ["paneID": UUID().uuidString, "targetVersion": UUID().uuidString]
        #expect(try CompanionRequestPolicy.authorizationOperation(for: request("watch_terminal", extra: pane)) == .connectionStatus)
        for extra in [[:], ["paneID": pane["paneID"]!], ["targetVersion": pane["targetVersion"]!]] {
            #expect(throws: LocalAPIError.invalidRequest) {
                try CompanionRequestPolicy.authorizationOperation(for: request("watch_terminal", extra: extra))
            }
        }
        #expect(throws: LocalAPIError.invalidRequest) {
            try CompanionRequestPolicy.authorizationOperation(for: request("list_panes", extra: pane))
        }
    }

    @Test func watchScopeRoundTripsAndInvalidShapeFailsToLoad() throws {
        let metadata = LocalAPICompanionMetadata(
            certificateFingerprint: fingerprint, transport: .lan, pairedAt: Date(), port: 1,
            terminalWatchScope: .persistentWorkspaces([UUID()]))
        let encoded = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: encoded).terminalWatchScope == metadata.terminalWatchScope)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "terminalWatchScope")
        #expect(
            try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONSerialization.data(withJSONObject: object))
                .terminalWatchScope == nil)
    }

    @Test func grantingWatchRotatesLeaseAndRevokingInvalidatesOldCommits() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let phone = try access.registerCompanion(phoneName: "One", certificateFingerprint: fingerprint, transport: .lan, port: 1)
        func lease() throws -> LocalAPIAuthorizationLease {
            try access.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        }
        let off = try lease()
        #expect(off.terminalWatchScope == nil)
        try access.updateCompanionTerminalWatchScope(connectionID: phone.id, scope: .allWorkspaces)
        let on = try lease()
        #expect(on.terminalWatchScope == .allWorkspaces)
        #expect(on.connectionRevision != off.connectionRevision)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: off) { 1 }
        }
        #expect(throws: LocalAPIAccessFailure.invalidScope) {
            try access.updateCompanionTerminalWatchScope(connectionID: phone.id, scope: .persistentPanes([]))
        }
        try access.updateCompanionTerminalWatchScope(connectionID: phone.id, scope: nil)
        #expect(try lease().terminalWatchScope == nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: on) { 1 }
        }
    }

    @Test func zmxParserReassemblesSplitMessagesAndRejectsOversize() throws {
        var parser = Relay.ZmxParser()
        let message = Relay.zmxMessage(.output, Data("hello".utf8)) + Relay.zmxMessage(.sessionEnd, Data([1]))
        var parsed: [Relay.ZmxMessage] = []
        for byte in message { parsed += try parser.feed(Data([byte])) }
        #expect(parsed == [.init(tag: 1, payload: Data("hello".utf8)), .init(tag: 14, payload: Data([1]))])
        var huge = Data([Relay.ZmxTag.output.rawValue])
        huge.append(contentsOf: withUnsafeBytes(of: UInt32(Stream.maximumSnapshotBytes + 1).littleEndian) { Data($0) })
        huge.append(contentsOf: [0, 0, 0])
        var oversize = Relay.ZmxParser()
        #expect(throws: Relay.ZmxParser.Failure.messageTooLarge) { try oversize.feed(huge) }
    }

    @Test func translatorEmitsSnapshotThenOutputAndEnds() throws {
        let paneID = UUID()
        let targetVersion = UUID()
        var translator = Relay.Translator(paneID: paneID, targetVersion: targetVersion, grid: .init(rows: 24, cols: 80))
        #expect(translator.translate(.init(tag: 1, payload: Data("early".utf8))) == .frames([]))
        #expect(translator.translate(.init(tag: 27, payload: Data(count: 16))) == .frames([]))
        var authority = Data()
        authority.append(contentsOf: withUnsafeBytes(of: UInt64(7).littleEndian) { Data($0) })
        authority.append(contentsOf: withUnsafeBytes(of: UInt64(1).littleEndian) { Data($0) })
        authority.append(contentsOf: withUnsafeBytes(of: UInt16(40).littleEndian) { Data($0) })
        authority.append(contentsOf: withUnsafeBytes(of: UInt16(100).littleEndian) { Data($0) })
        #expect(translator.translate(.init(tag: 28, payload: authority)) == .frames([]))
        #expect(!translator.snapshotConstructed)
        let snapshot = Data(repeating: 0x41, count: Stream.maximumDataBytes + 1)
        let begin = Stream.SnapshotBegin(
            paneID: paneID.uuidString.lowercased(), targetVersion: targetVersion.uuidString.lowercased(),
            grid: .init(rows: 40, cols: 100), leader: "7", scrollbackBound: Stream.maximumSnapshotBytes)
        #expect(
            translator.translate(.init(tag: 1, payload: snapshot))
                == .frames([
                    .snapshotBegin(begin),
                    .snapshot(sequence: 0, bytes: snapshot.prefix(Stream.maximumDataBytes)),
                    .snapshot(sequence: 1, bytes: Data([0x41])),
                    .snapshotEnd(.init(bytes: snapshot.count)),
                ]))
        #expect(translator.snapshotConstructed)
        #expect(translator.translate(.init(tag: 1, payload: Data("hi".utf8))) == .frames([.output(sequence: 2, bytes: Data("hi".utf8))]))
        #expect(
            translator.translate(.init(tag: 28, payload: authority))
                == .frames([.leader(.init(leader: "7")), .grid(.init(rows: 40, cols: 100))]))
        #expect(translator.translate(.init(tag: 14, payload: Data([1]))) == .end(.sessionEnded))
    }
}

// Failure modes: cancelled Network.framework callbacks must finish without a
// callback; overflow must discard bytes atomically and await the active write;
// only a delivered snapshot permits resync; listeners share limits until cleanup.
@MainActor
@Suite("Companion terminal watch lifecycle")
struct CompanionTerminalWatchLifecycleTests {
    typealias Relay = CompanionTerminalWatchRelay
    typealias Stream = CompanionTerminalStream

    // A delayed snapshot must not let heartbeat become the first frame, or
    // interrupt a snapshot whose end has only been queued or submitted.
    @Test func heartbeatWaitsForDeliveredSnapshotEndInEveryGeneration() throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        #expect(buffer.takeHeartbeat() == nil)
        #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
        #expect(buffer.takeHeartbeat() == nil)
        let end = try #require(buffer.takeFrame())
        #expect(buffer.takeHeartbeat() == nil)
        buffer.didWrite(end)
        let heartbeat = try #require(buffer.takeHeartbeat())
        buffer.didWrite(heartbeat)
        #expect(buffer.beginGeneration() == generation + 1)
        #expect(buffer.takeHeartbeat() == nil)
    }

    @Test func acceptedAttachWithoutSnapshotExpiresBeforeAnyHeartbeat() async {
        let buffer = Relay.Buffer()
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finalReasons: [Stream.EndReason] = []
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: { try await CompanionNetworkOperation<Data>().wait {} },
            send: { _ in Issue.record("Frame sent before initial snapshot") },
            sendEnd: { data in
                if case .end(let end) = try Stream.decode(data).frame { finalReasons.append(end.reason) }
            },
            delay: { duration in
                if duration == .seconds(5) {
                    for await _ in started { break }
                    clock.withLock { $0 = $0.advanced(by: .seconds(15)) }
                    await Task.yield()
                } else {
                    try await ContinuousClock().sleep(for: duration)
                }
            },
            now: { clock.withLock { $0 } },
            produce: { buffer in
                _ = buffer.beginGeneration()
                var translator = Relay.Translator(paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80))
                #expect(translator.translate(.init(tag: 27, payload: Data(count: 16))) == .frames([]))
                signal.yield(())
                signal.finish()
                _ = try? await CompanionNetworkOperation<Void>().wait {}
            })
        #expect(reason == .paneUnavailable)
        #expect(finalReasons == [.paneUnavailable])
    }

    // Readiness and attach-send can both stall without a Network callback.
    @Test(arguments: [true, false])
    func attachPreparationDeadlineCancelsEitherStalledStage(stallReadiness: Bool) async {
        let blocked = CompanionNetworkOperation<Void>()
        let cancelled = CompanionNetworkOperation<Void>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let result = await Relay.prepareAttach(
            ready: {
                if stallReadiness { try await blocked.wait { signal.yield(()) } }
            },
            sendAttach: {
                if stallReadiness { Issue.record("Attach sent before readiness") }
                try await blocked.wait { signal.yield(()) }
            },
            cancel: { cancelled.resolve(.success(())) },
            delay: { duration in
                #expect(duration == Relay.acceptTimeout)
                for await _ in started { break }
            })
        #expect(result == .end(.paneUnavailable))
        #expect(!blocked.resolve(.success(())))
        #expect(!cancelled.resolve(.success(())))
    }

    @Test func cancellingAttachPreparationCancelsSocketAndCallbackWait() async {
        let blocked = CompanionNetworkOperation<Void>()
        let cancelled = CompanionNetworkOperation<Void>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await Relay.prepareAttach(
                ready: { try await blocked.wait { signal.yield(()) } },
                sendAttach: { Issue.record("Cancelled attach sent") },
                cancel: { cancelled.resolve(.success(())) },
                delay: { try await ContinuousClock().sleep(for: $0) })
        }
        for await _ in started { break }
        task.cancel()
        #expect(await task.value == .end(.paneUnavailable))
        #expect(!blocked.resolve(.success(())))
        #expect(!cancelled.resolve(.success(())))
    }

    // A valid snapshot can be larger than the pending buffer. Its dedicated
    // daemon socket may wait for the phone, while live output still overflows.
    @Test(arguments: [5 * 1024 * 1024, Stream.maximumSnapshotBytes])
    func largeSnapshotPacesWithoutOverflowAndPreservesOrderedOutput(snapshotBytes: Int) async throws {
        let buffer = Relay.Buffer()
        var translator = Relay.Translator(paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80))
        _ = translator.translate(.init(tag: 27, payload: Data(count: 16)))
        let snapshot = Data(repeating: 0x41, count: snapshotBytes)
        guard case .frames(let frames) = translator.translate(.init(tag: 1, payload: snapshot)) else {
            Issue.record("Missing snapshot frames"); return
        }
        var written: [Stream.Frame] = []
        var peakPending = 0
        let tail = Stream.Frame.output(sequence: UInt64(snapshotBytes / Stream.maximumDataBytes), bytes: Data("tail".utf8))
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: { try await CompanionNetworkOperation<Data>().wait {} },
            send: { data in
                peakPending = max(peakPending, buffer.pendingBytes)
                written.append(try Stream.decode(data).frame)
            },
            sendEnd: { _ in },
            delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { buffer in
                guard let generation = buffer.beginGeneration() else { return }
                for frame in frames {
                    do {
                        let result = try await buffer.enqueueSnapshot(frame, generation: generation)
                        guard result == .continue else { buffer.finish(.overflow); return }
                    } catch { return }
                }
                _ = buffer.enqueue(tail, generation: generation)
                buffer.finish(.sessionEnded)
            })
        #expect(reason == .sessionEnded)
        #expect(buffer.generation == 1)
        #expect(written == frames + [tail])
        #expect(peakPending <= Stream.maximumPendingBytes)
        #expect(buffer.pendingBytes == 0)
    }

    @Test(arguments: [true, false])
    func snapshotPacingCountsInFlightAndWakesOnCancellationOrStop(cancel: Bool) async throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 64)
        let generation = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshot(sequence: 0, bytes: Data(count: 40)), generation: generation) == .continue)
        let inFlight = try #require(buffer.takeFrame())
        let task = Task {
            try await buffer.enqueueSnapshot(.snapshot(sequence: 1, bytes: Data(count: 40)), generation: generation)
        }
        // The active write remains charged even though the queue is empty.
        await Task.yield()
        #expect(buffer.pendingBytes == inFlight.data.count)
        #expect(buffer.takeFrame() == nil)
        if cancel { task.cancel() } else { buffer.stop(.revoked) }
        do {
            #expect(try await task.value == .end(.revoked))
            #expect(!cancel)
        } catch { #expect(cancel && error is CancellationError) }
        #expect(buffer.pendingBytes == inFlight.data.count)
        buffer.didWrite(inFlight)
        #expect(buffer.pendingBytes == 0)
    }

    @Test(
        arguments: [
            Stream.EndReason.closed, .superseded, .revoked, .paneUnavailable, .sessionEnded, .roleChanged, .protocolError, .overflow,
        ],
        [true, false])
    func phoneEndAcceptsOnlyCurrentGenerationClosed(reason: Stream.EndReason, current: Bool) async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        let data = try Stream.encode(.end(.init(reason: reason)), generation: current ? generation : generation - 1)
        var finalReasons: [Stream.EndReason] = []
        let result = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: { data },
            send: { _ in Issue.record("Unexpected data frame") },
            sendEnd: { data in
                if case .end(let end) = try Stream.decode(data).frame { finalReasons.append(end.reason) }
            },
            delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { _ in _ = try? await CompanionNetworkOperation<Void>().wait {} })
        let expected: Stream.EndReason = current && reason == .closed ? .closed : .protocolError
        #expect(result == expected)
        #expect(finalReasons == [expected])
    }

    @Test(arguments: [UInt32(0), UInt32(1)])
    func ackRemainsHarmlessBeforeCurrentGenerationClose(ackGeneration: UInt32) async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        var ack = Data([Stream.FrameType.ack.rawValue])
        ack.append(contentsOf: withUnsafeBytes(of: ackGeneration.bigEndian, Array.init))
        ack.append(contentsOf: Data("{}".utf8))
        let frames = [ack, try Stream.encode(.end(.init(reason: .closed)), generation: generation)]
        let next = OSAllocatedUnfairLock(initialState: 0)
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: {
                let index = next.withLock { value in
                    defer { value += 1 }; return value
                }
                return frames[index]
            },
            send: { _ in Issue.record("Unexpected data frame") },
            sendEnd: { _ in },
            delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { _ in _ = try? await CompanionNetworkOperation<Void>().wait {} })
        #expect(reason == .closed)
        #expect(next.withLock { $0 } == 2)
    }

    @Test func cancelledCallbackWaitFinishesAndIgnoresLateCompletion() async {
        let operation = CompanionNetworkOperation<Data>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await operation.wait { signal.yield(()) }
        }
        for await _ in started { break }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled receive stayed successful")
        } catch { #expect(error is CancellationError) }
        #expect(!operation.resolve(.success(Data([1]))))
    }

    @Test func cancellingBeforeRegistrationDoesNotStartNetworkWork() async {
        let operation = CompanionNetworkOperation<Data>()
        #expect(operation.resolve(.failure(CancellationError())))
        do {
            _ = try await operation.wait { Issue.record("Cancelled operation started") }
            Issue.record("Cancelled operation succeeded")
        } catch { #expect(error is CancellationError) }
    }

    @Test func overflowDropsGenerationAndWaitsForActiveWrite() async throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 128)
        let generation = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
        let snapshotEnd = try #require(buffer.takeFrame())
        buffer.didWrite(snapshotEnd)
        #expect(buffer.enqueue(.output(sequence: 0, bytes: Data(repeating: 1, count: 40)), generation: generation) == .continue)
        let inFlight = try #require(buffer.takeFrame())
        #expect(buffer.enqueue(.output(sequence: 1, bytes: Data(repeating: 2, count: 40)), generation: generation) == .continue)
        #expect(buffer.enqueue(.output(sequence: 2, bytes: Data(repeating: 3, count: 40)), generation: generation) == .overflow)
        #expect(buffer.pendingBytes == inFlight.data.count)
        #expect(buffer.takeFrame() == nil)
        #expect(buffer.beginGeneration() == nil)
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let drained = Task {
            signal.yield(())
            try await buffer.waitForDrain()
        }
        for await _ in waiting { break }
        buffer.didWrite(inFlight)
        try await drained.value
        #expect(buffer.pendingBytes == 0)
        let next = try #require(buffer.beginGeneration())
        #expect(next == generation + 1)
        #expect(buffer.enqueue(.output(sequence: 3, bytes: Data([9])), generation: generation) == .overflow)
        #expect(buffer.pendingBytes == 0)
    }

    @Test func constructedOrInFlightSnapshotEndDoesNotPermitResync() throws {
        for snapshotEndInFlight in [false, true] {
            let buffer = Relay.Buffer(maximumPendingBytes: 128)
            let generation = try #require(buffer.beginGeneration())
            #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
            if snapshotEndInFlight { _ = buffer.takeFrame() }
            #expect(buffer.enqueue(.output(sequence: 0, bytes: Data(count: 128)), generation: generation) == .end(.overflow))
            #expect(buffer.endReason == .overflow)
            #expect(buffer.beginGeneration() == nil)
        }
    }

    @Test func repeatedOverflowBeforeReplacementSnapshotDeliveryEndsStream() throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 128)
        let first = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: first) == .continue)
        buffer.didWrite(try #require(buffer.takeFrame()))
        #expect(buffer.enqueue(.output(sequence: 0, bytes: Data(count: 128)), generation: first) == .overflow)
        let second = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshot(sequence: 0, bytes: Data(count: 128)), generation: second) == .end(.overflow))
        #expect(buffer.endReason == .overflow)
    }

    @Test func registrySharesDeviceAndMacLimitsAcrossListeners() async throws {
        let registry = CompanionTerminalWatchRegistry()
        let phone = UUID()
        var ids: [UUID] = []
        for device in [phone, phone, UUID(), UUID()] {
            let id = UUID()
            try await registry.reserve(id: id, connectionID: device, paneID: UUID(), stop: { _ in })
            ids.append(id)
        }
        await #expect(throws: LocalAPIError.endpointBusy) {
            try await registry.reserve(id: UUID(), connectionID: phone, paneID: UUID(), stop: { _ in })
        }
        await #expect(throws: LocalAPIError.endpointBusy) {
            try await registry.reserve(id: UUID(), connectionID: UUID(), paneID: UUID(), stop: { _ in })
        }
        registry.release(ids.removeLast())
        await #expect(throws: LocalAPIError.endpointBusy) {
            try await registry.reserve(id: UUID(), connectionID: phone, paneID: UUID(), stop: { _ in })
        }
        registry.release(ids.removeFirst())
        try await registry.reserve(id: UUID(), connectionID: phone, paneID: UUID(), stop: { _ in })
    }

    @Test func supersedingSuspendedWriteReleasesReservationWithoutDeadline() async throws {
        let registry = CompanionTerminalWatchRegistry()
        let buffer = Relay.Buffer()
        let phone = UUID(), pane = UUID(), old = UUID(), replacement = UUID()
        try await registry.reserve(id: old, connectionID: phone, paneID: pane, stop: { buffer.stop($0) })
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finalFrameSent = false
        let worker = Task {
            defer { registry.release(old) }
            return await Relay.run(
                socketPath: "unused", paneID: pane, targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
                buffer: buffer,
                phoneFrames: { try await CompanionNetworkOperation<Data>().wait {} },
                send: { _ in try await CompanionNetworkOperation<Void>().wait { signal.yield(()) } },
                sendEnd: { _ in finalFrameSent = true },
                delay: { _ in try await CompanionNetworkOperation<Void>().wait {} },
                produce: { buffer in
                    guard let generation = buffer.beginGeneration() else { return }
                    _ = buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation)
                })
        }
        for await _ in started { break }
        try await registry.reserve(id: replacement, connectionID: phone, paneID: pane, stop: { _ in })
        #expect(await worker.value == .superseded)
        #expect(registry.contains(replacement))
        #expect(!registry.contains(old))
        #expect(!finalFrameSent)
        registry.release(replacement)
    }

    @Test func supersedingAcrossListenersRetainsReservationUntilCleanup() async throws {
        let registry = CompanionTerminalWatchRegistry()
        let phone = UUID(), pane = UUID(), old = UUID(), replacement = UUID()
        let (stopped, signal) = AsyncStream<Stream.EndReason>.makeStream()
        try await registry.reserve(id: old, connectionID: phone, paneID: pane, stop: { signal.yield($0) })
        let task = Task {
            try await registry.reserve(id: replacement, connectionID: phone, paneID: pane, stop: { _ in })
        }
        for await reason in stopped { #expect(reason == .superseded); break }
        #expect(registry.contains(old))
        #expect(!registry.contains(replacement))
        registry.release(old)
        try await task.value
        #expect(registry.contains(replacement))
    }

    @Test(arguments: [Stream.EndReason.revoked, .superseded])
    func invalidationCancelsIdleProducerAndReaderBeforeFinalReason(endReason: Stream.EndReason) async throws {
        let buffer = Relay.Buffer()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finalReasons: [Stream.EndReason] = []
        let worker = Task {
            await Relay.run(
                socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
                buffer: buffer,
                phoneFrames: {
                    try await CompanionNetworkOperation<Data>().wait { signal.yield(()) }
                },
                send: { _ in Issue.record("Unexpected data write") },
                sendEnd: { data in
                    guard case .end(let end) = try Stream.decode(data).frame else {
                        Issue.record("Missing final end"); return
                    }
                    finalReasons.append(end.reason)
                },
                delay: { try await ContinuousClock().sleep(for: $0) },
                produce: { buffer in
                    _ = buffer.beginGeneration()
                    _ = try? await CompanionNetworkOperation<Void>().wait { signal.yield(()) }
                })
        }
        var count = 0
        for await _ in started { count += 1; if count == 2 { break } }
        buffer.stop(endReason)
        #expect(await worker.value == endReason)
        #expect(finalReasons == [endReason])
    }

    @Test func heartbeatWriteMustDrainBeforeOverflowReattach() throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 128)
        let generation = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
        buffer.didWrite(try #require(buffer.takeFrame()))
        let heartbeat = try #require(buffer.takeHeartbeat())
        #expect(buffer.enqueue(.output(sequence: 0, bytes: Data(count: 128)), generation: generation) == .overflow)
        #expect(buffer.beginGeneration() == nil)
        buffer.didWrite(heartbeat)
        #expect(buffer.beginGeneration() == generation + 1)
    }

    @Test func fourthOverflowWithinMinuteEndsEvenAfterDeliveredSnapshots() throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 128)
        for restart in 1...4 {
            let generation = try #require(buffer.beginGeneration())
            #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
            buffer.didWrite(try #require(buffer.takeFrame()))
            let result = buffer.enqueue(.output(sequence: 0, bytes: Data(count: 128)), generation: generation)
            #expect(result == (restart <= 3 ? .overflow : .end(.overflow)))
        }
        #expect(buffer.beginGeneration() == nil)
    }

    @Test(arguments: [true, false])
    func failedWriteSendsFinalReasonOnlyAtKnownFrameBoundary(atFrameBoundary: Bool) async {
        let buffer = Relay.Buffer()
        var finalReasons: [Stream.EndReason] = []
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: { try await CompanionNetworkOperation<Data>().wait {} },
            send: { _ in throw Relay.WriteFailure(reason: .revoked, atFrameBoundary: atFrameBoundary) },
            sendEnd: { data in
                if case .end(let end) = try Stream.decode(data).frame { finalReasons.append(end.reason) }
            },
            delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { buffer in
                if let generation = buffer.beginGeneration() {
                    _ = buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation)
                }
            })
        #expect(reason == .revoked)
        #expect(finalReasons == (atFrameBoundary ? [.revoked] : []))
    }

    @Test func watchWorkspaceConsentIsIndependentAndEmptyDisablesIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let fingerprint = Data(repeating: 7, count: 32)
        let phone = try access.registerCompanion(phoneName: "One", certificateFingerprint: fingerprint, transport: .lan, port: 1)
        let coordinator = CompanionPairingCoordinator(profile: .development(worktreeID: nil), accessStore: access)
        let workspace = UUID()
        try coordinator.setTerminalWatchWorkspaces([workspace], for: phone)
        let lease = try access.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        #expect(lease.terminalWatchScope == .persistentWorkspaces([workspace]))
        try coordinator.setTerminalWatchWorkspaces([], for: phone)
        let disabled = try access.runtimeAuthority.authorizeCompanion(
            connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
        ).get()
        #expect(disabled.terminalWatchScope == nil)
    }

    @Test func watchesHaveSeparateAdmissionBudgetAndHandshakesStayBounded() {
        typealias Admission = CompanionClientAdmission
        let watches = Array(repeating: Admission.Kind.watch, count: Stream.maximumStreamsPerMac)
        #expect(Admission.allows(watches + Array(repeating: .request, count: LocalAPIContract.maximumClients - 1)))
        #expect(!Admission.allows(watches + Array(repeating: .request, count: LocalAPIContract.maximumClients)))
        #expect(!Admission.allows(watches + Array(repeating: .handshake, count: LocalAPIContract.maximumClients)))
        #expect(!Admission.allows(watches + Array(repeating: .request, count: 4) + Array(repeating: .handshake, count: 4)))
    }

    @Test func chunkValidationRejectsChangedTargetBeforeSecondSubmissionAndCloses() async {
        var targetIsCurrent = true
        var chunks: [Data] = []
        var closed = false
        do {
            try await Relay.writeChunks(
                Data(count: 32 * 1024),
                validate: { if !targetIsCurrent { throw Stream.EndReason.paneUnavailable } },
                submit: { chunk, beforeSubmit in
                    try beforeSubmit()
                    chunks.append(chunk)
                    targetIsCurrent = false
                }, close: { closed = true })
            Issue.record("Changed target continued streaming")
        } catch let failure as Relay.ChunkWriteFailure {
            #expect(!failure.atFrameBoundary)
            #expect(failure.underlying as? Stream.EndReason == .paneUnavailable)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(chunks.map(\.count) == [16 * 1024])
        #expect(closed)
    }

    @Test func validationRunsAtSubmissionAfterAsyncWait() async {
        var targetIsCurrent = true
        var submitted = false
        var closed = false
        do {
            try await Relay.writeChunks(
                Data(count: 10),
                validate: { if !targetIsCurrent { throw Stream.EndReason.paneUnavailable } },
                submit: { _, beforeSubmit in
                    await Task.yield()
                    targetIsCurrent = false
                    try beforeSubmit()
                    submitted = true
                }, close: { closed = true })
            Issue.record("Stale target was accepted")
        } catch let failure as Relay.ChunkWriteFailure {
            #expect(failure.atFrameBoundary)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(!submitted)
        #expect(!closed)
    }

    @Test func stalledFinalEndDeliveryIsBoundedAfterProducerCleanup() async {
        let buffer = Relay.Buffer()
        let blockedEnd = CompanionNetworkOperation<Void>()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: { try await CompanionNetworkOperation<Data>().wait {} },
            send: { _ in Issue.record("Unexpected data frame") },
            sendEnd: { _ in try await blockedEnd.wait { signal.yield(()) } },
            delay: { duration in
                if duration == Relay.finalWriteTimeout {
                    for await _ in started { break }
                } else {
                    try await ContinuousClock().sleep(for: duration)
                }
            },
            produce: { buffer in
                _ = buffer.beginGeneration()
                buffer.finish(.sessionEnded)
            })
        #expect(reason == .sessionEnded)
        #expect(!blockedEnd.resolve(.success(())))
    }

    @Test func cancelledReplacementDoesNotLeakReservation() async throws {
        let registry = CompanionTerminalWatchRegistry()
        let phone = UUID(), pane = UUID(), old = UUID(), replacement = UUID()
        let (stopped, signal) = AsyncStream<Void>.makeStream()
        try await registry.reserve(id: old, connectionID: phone, paneID: pane, stop: { _ in signal.yield(()) })
        let task = Task {
            try await registry.reserve(id: replacement, connectionID: phone, paneID: pane, stop: { _ in })
        }
        for await _ in stopped { break }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled replacement was reserved") } catch {
            #expect(error is CancellationError)
        }
        #expect(registry.contains(old))
        #expect(!registry.contains(replacement))
        registry.release(old)
        try await registry.reserve(id: replacement, connectionID: phone, paneID: pane, stop: { _ in })
    }

    @Test func writeAndFinalEndTimeoutCancelSuspendedSend() async {
        for timeout in [Relay.writeTimeout, Relay.finalWriteTimeout] {
            let (started, signal) = AsyncStream<Void>.makeStream()
            let result = await Relay.write(
                Data([1]),
                send: { _ in try await CompanionNetworkOperation<Void>().wait { signal.yield(()) } },
                delay: { _ in for await _ in started { break } }, timeout: timeout)
            #expect(result?.reason == .closed)
        }
    }
}
