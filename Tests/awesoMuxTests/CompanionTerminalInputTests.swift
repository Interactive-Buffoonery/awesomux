import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing

@testable import awesoMux

/// Input failures must stop at the Mac boundary before any daemon mutation.
@MainActor
@Suite("Companion terminal input")
struct CompanionTerminalInputTests {
    typealias Stream = CompanionTerminalStream
    typealias Relay = CompanionTerminalWatchRelay

    @Test func roleAssignmentExplainsWatchAndNeverTypesRemotePanes() {
        #expect(CompanionTerminalAuthorization.accepted(inputAllowed: true, local: true) == .init(role: .interactive))
        #expect(CompanionTerminalAuthorization.accepted(inputAllowed: false, local: true) == .init(role: .watch, watchReason: .inputOff))
        for input in [false, true] {
            #expect(
                CompanionTerminalAuthorization.accepted(inputAllowed: input, local: false) == .init(role: .watch, watchReason: .remotePane))
        }
    }

    @Test func inputIsDefaultOffPersistsAndRequiresWatch() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let fingerprint = Data(repeating: 7, count: 32)
        let phone = try access.registerCompanion(phoneName: "iPhone", certificateFingerprint: fingerprint, transport: .lan, port: 1)
        #expect(phone.companion?.terminalInputAllowed == false)
        #expect(throws: LocalAPIAccessFailure.invalidScope) {
            try access.updateCompanionTerminalInputAllowed(connectionID: phone.id, allowed: true)
        }
        try access.updateCompanionTerminalWatchScope(connectionID: phone.id, scope: .allWorkspaces)
        try access.updateCompanionTerminalInputAllowed(connectionID: phone.id, allowed: true)
        let metadata = try #require(access.state.connections.first { $0.id == phone.id }?.companion)
        #expect(try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONEncoder().encode(metadata)).terminalInputAllowed)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        old.removeValue(forKey: "terminalInputAllowed")
        #expect(
            try !JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONSerialization.data(withJSONObject: old))
                .terminalInputAllowed)
        access.relinquishAuthority()
        let restored = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        #expect(restored.loadFailure == nil)
        #expect(restored.state.connections.first { $0.id == phone.id }?.companion?.terminalInputAllowed == true)
        try restored.updateCompanionTerminalWatchScope(connectionID: phone.id, scope: nil)
        #expect(restored.state.connections.first { $0.id == phone.id }?.companion?.terminalInputAllowed == true)
        let retained = try #require(restored.state.connections.first { $0.id == phone.id }?.companion)
        #expect(try JSONDecoder().decode(LocalAPICompanionMetadata.self, from: JSONEncoder().encode(retained)).terminalInputAllowed)
        try restored.updateCompanionTerminalInputAllowed(connectionID: phone.id, allowed: false)
        #expect(restored.state.connections.first { $0.id == phone.id }?.companion?.terminalInputAllowed == false)

    }

    @Test func inputToggleChangesLocalRoleButRetainsRemoteWatchAndGrantLossRevokes() throws {
        let initial = lease(input: false)
        let local = CompanionTerminalAuthorization(lease: initial, accepted: .init(role: .watch, watchReason: .inputOff), local: true)
        #expect(throws: Stream.EndReason.roleChanged) { try local.validate(lease(input: true), targetIsCurrent: true) }
        let remote = CompanionTerminalAuthorization(lease: initial, accepted: .init(role: .watch, watchReason: .remotePane), local: false)
        try remote.validate(lease(input: true), targetIsCurrent: true)
        #expect(throws: Stream.EndReason.revoked) { try remote.validate(lease(input: false, watch: false), targetIsCurrent: true) }
        #expect(throws: Stream.EndReason.paneUnavailable) { try local.validate(initial, targetIsCurrent: false) }
        #expect(throws: Stream.EndReason.revoked) { try local.validate(lease(input: false, revision: UUID()), targetIsCurrent: true) }
    }

    @Test func settingsToggleChangesStreamRoleAndTerminalRevocationWins() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: home)
        let fingerprint = Data(repeating: 8, count: 32)
        let phone = try access.registerCompanion(phoneName: "iPhone", certificateFingerprint: fingerprint, transport: .lan, port: 1)
        let coordinator = CompanionPairingCoordinator(profile: .development(worktreeID: nil), accessStore: access)
        try coordinator.setTerminalWatchAllowed(true, for: phone)
        func currentLease() throws -> LocalAPIAuthorizationLease {
            try access.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint, operation: .connectionStatus
            ).get()
        }
        let initial = try currentLease()
        let watcher = CompanionTerminalAuthorization(lease: initial, accepted: .init(role: .watch, watchReason: .inputOff), local: true)
        let remote = CompanionTerminalAuthorization(lease: initial, accepted: .init(role: .watch, watchReason: .remotePane), local: false)
        try coordinator.setTerminalInputAllowed(true, for: phone)
        let enabled = try currentLease()
        #expect(throws: Stream.EndReason.roleChanged) { try watcher.validate(enabled, targetIsCurrent: true) }
        try remote.validate(enabled, targetIsCurrent: true)
        let interactive = CompanionTerminalAuthorization(lease: enabled, accepted: .init(role: .interactive), local: true)
        try coordinator.setTerminalInputAllowed(false, for: phone)
        #expect(throws: Stream.EndReason.roleChanged) { try interactive.validate(currentLease(), targetIsCurrent: true) }
        try coordinator.setTerminalWatchAllowed(false, for: phone)
        #expect(throws: Stream.EndReason.revoked) { try interactive.validate(currentLease(), targetIsCurrent: true) }
    }

    private let connectionID = UUID(), revision = UUID()
    private func lease(input: Bool, watch: Bool = true, revision: UUID? = nil) -> LocalAPIAuthorizationLease {
        let revision = revision ?? self.revision
        return .init(
            connectionID: connectionID, globalRevision: revision, connectionRevision: revision, statusScope: .allWorkspaces,
            terminalWatchScope: watch ? .allWorkspaces : nil, terminalInputAllowed: input)
    }

    @Test func typedBatchesCarryAttachmentRevisionGridAndExactBytes() throws {
        var input = Relay.InputState(role: .interactive, grid: .init(rows: 24, cols: 80))
        input.attach(id: 42, revision: 9)
        #expect(try input.message(.grid(.init(rows: 24, cols: 40))) == nil)
        let bytes = Data("\u{1b}[200~hello\n\u{1b}[201~\r".utf8)
        let batchMessage = try input.message(.input(sequence: 8, bytes: bytes))
        let batch = try #require(batchMessage)
        #expect(batch == Relay.zmxMessage(.userBatch, typedHeader(rows: 24, cols: 40) + bytes))
        let claimMessage = try input.message(.claim(.init(grid: .init(rows: 30, cols: 90))))
        let claim = try #require(claimMessage)
        #expect(claim == Relay.zmxMessage(.takeOver, typedHeader(rows: 30, cols: 90)))
        #expect(
            try input.message(.input(sequence: 9, bytes: Data([27])))
                == Relay.zmxMessage(.userBatch, typedHeader(rows: 30, cols: 90) + Data([27])))
        #expect(Relay.attachRequest(.init(rows: 24, cols: 40), role: .interactive)[9] == 2)
        #expect(Relay.attachRequest(.init(rows: 24, cols: 40))[9] == 1)
    }

    private func typedHeader(rows: UInt16, cols: UInt16) -> Data {
        var data = Data()
        for value: UInt64 in [42, 9] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value in [rows, cols] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    @Test func invalidInputAndWatchMutationsAreProtocolErrors() throws {
        for role in [Stream.Role.watch, .interactive] {
            var input = Relay.InputState(role: role, grid: .init(rows: 24, cols: 80))
            input.attach(id: 42, revision: 9)
            for frame: Stream.Frame in [
                .input(sequence: 0, bytes: Data()), .input(sequence: 0, bytes: Data(count: Stream.maximumInputBytes + 1)),
                .phoneSent(.reply), .ack(.init(sequence: 0)),
            ] {
                #expect(throws: Stream.EndReason.protocolError) { try input.message(frame) }
            }
            if role == .watch {
                for frame: Stream.Frame in [
                    .input(sequence: 0, bytes: Data([13])), .claim(.init(grid: .init(rows: 24, cols: 80))),
                    .grid(.init(rows: 24, cols: 80)),
                ] {
                    #expect(throws: Stream.EndReason.protocolError) { try input.message(frame) }
                }
            }
        }
    }

    @Test func gridBoundsAndMaximumInputBoundary() throws {
        var input = Relay.InputState(role: .interactive, grid: .init(rows: 24, cols: 80))
        input.attach(id: 42, revision: 9)
        for grid in [Stream.Grid(rows: 0, cols: 80), .init(rows: 24, cols: 1001)] {
            #expect(throws: Stream.EndReason.protocolError) { try input.message(.grid(grid)) }
            #expect(throws: Stream.EndReason.protocolError) { try input.message(.claim(.init(grid: grid))) }
        }
        #expect(
            try input.message(.input(sequence: 1, bytes: Data(count: Stream.maximumInputBytes)))?.count == Relay.zmxHeaderBytes + 20
                + Stream.maximumInputBytes)
    }

    @Test func staleGenerationDropsBeforeDecodeAndAcksHighestForwardedSequence() async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        var writes: [Data] = []
        let forwarder = Relay.InputForwarder(role: .interactive, grid: .init(rows: 24, cols: 80), buffer: buffer)
        forwarder.install(
            generation: generation, id: 42, revision: 9,
            submit: { data, validate in
                try validate(); writes.append(data)
            })
        try await forwarder.receive(Data([16, 0, 0, 0, 0]))
        #expect(writes.isEmpty)
        for sequence: UInt64 in [8, 3, 10] {
            try await forwarder.receive(Stream.encode(.input(sequence: sequence, bytes: Data([13])), generation: generation))
            let ack = try #require(buffer.takeFrame())
            #expect(try Stream.decode(ack.data).frame == .ack(.init(sequence: sequence == 3 ? 8 : sequence)))
            buffer.didWrite(ack)
        }
        #expect(writes.count == 3)
        forwarder.detach(generation: generation)
        try await forwarder.receive(Stream.encode(.input(sequence: 11, bytes: Data([27])), generation: generation))
        #expect(writes.count == 3)
        #expect(buffer.takeFrame() == nil)
        #expect(buffer.endReason == nil)
        let next = try #require(buffer.beginGeneration())
        forwarder.install(
            generation: next, id: 43, revision: 1,
            submit: { data, validate in
                try validate(); writes.append(data)
            })
        try await forwarder.receive(Stream.encode(.input(sequence: 11, bytes: Data([27])), generation: generation))
        #expect(writes.count == 3)
        try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: next))
        #expect(try Stream.decode(#require(buffer.takeFrame()).data).frame == .ack(.init(sequence: 1)))
    }

    @Test func reattachRaceDropsInputWithoutForwardingOrAck() async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        var writes: [Data] = []
        let forwarder = Relay.InputForwarder(role: .interactive, grid: .init(rows: 24, cols: 80), buffer: buffer)
        let submit: Relay.InputForwarder.Submit = { data, validate in
            try validate(); writes.append(data)
        }
        forwarder.install(generation: generation, id: 42, revision: 9, submit: submit)
        let next = try #require(buffer.beginGeneration())
        try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: next))
        #expect(writes.isEmpty)
        #expect(buffer.takeFrame() == nil)
        forwarder.install(generation: next + 1, id: 43, revision: 1, submit: submit)
        try await forwarder.receive(Stream.encode(.input(sequence: 2, bytes: Data([13])), generation: next))
        #expect(writes.isEmpty)
        #expect(buffer.takeFrame() == nil)
        #expect(buffer.endReason == nil)
        #expect(buffer.beginGeneration() == next + 1)
        try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: next + 1))
        #expect(writes.count == 1)
        #expect(try Stream.decode(#require(buffer.takeFrame()).data).frame == .ack(.init(sequence: 1)))
    }

    @Test func revocationAtSubmissionForwardsNothingAndSendsNoAck() async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        var allowed = true, submitted = false
        let forwarder = Relay.InputForwarder(
            role: .interactive, grid: .init(rows: 24, cols: 80), buffer: buffer,
            validate: { if !allowed { throw Stream.EndReason.revoked } })
        forwarder.install(
            generation: generation, id: 42, revision: 9,
            submit: { _, validate in
                await Task.yield()
                allowed = false
                try validate()
                submitted = true
            })
        await #expect(throws: Stream.EndReason.revoked) {
            try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: generation))
        }
        #expect(!submitted)
        #expect(buffer.takeFrame() == nil)
    }
    @Test func ackOverflowInterruptsQuietDaemonForFreshGeneration() async throws {
        let buffer = Relay.Buffer(maximumPendingBytes: 128)
        let generation = try #require(buffer.beginGeneration())
        #expect(buffer.enqueue(.snapshotEnd(.init(bytes: 0)), generation: generation) == .continue)
        buffer.didWrite(try #require(buffer.takeFrame()))
        #expect(buffer.enqueue(.output(sequence: 0, bytes: Data(count: 100)), generation: generation) == .continue)
        var interrupted = false
        let forwarder = Relay.InputForwarder(role: .interactive, grid: .init(rows: 24, cols: 80), buffer: buffer)
        forwarder.install(
            generation: generation, id: 42, revision: 9, resync: { interrupted = true }, submit: { _, validate in try validate() })
        try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: generation))
        #expect(interrupted)
        #expect(buffer.needsResync(generation: generation))
        #expect(!buffer.acceptsInput(generation: generation))
        #expect(buffer.beginGeneration() == generation + 1)
        #expect(buffer.takeFrame() == nil)
    }

    @Test func generationChangeDuringSubmissionDropsInputWithoutAck() async throws {
        let buffer = Relay.Buffer()
        let generation = try #require(buffer.beginGeneration())
        var submitted = false
        let forwarder = Relay.InputForwarder(role: .interactive, grid: .init(rows: 24, cols: 80), buffer: buffer)
        forwarder.install(
            generation: generation, id: 42, revision: 9,
            submit: { _, validate in
                await Task.yield()
                #expect(buffer.beginGeneration() == generation + 1)
                try validate()
                submitted = true
            })
        try await forwarder.receive(Stream.encode(.input(sequence: 1, bytes: Data([13])), generation: generation))
        #expect(buffer.endReason == nil)
        #expect(!submitted)
        #expect(buffer.takeFrame() == nil)
    }

    @Test(arguments: [false, true])
    func malformedInputEndsStreamWithProtocolError(oversized: Bool) async {
        let buffer = Relay.Buffer()
        let ready = CompanionNetworkOperation<Void>()
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: buffer,
            phoneFrames: {
                try await ready.wait {}
                var data = Data([16, 0, 0, 0, 1]) + Data(count: Stream.sequenceBytes)
                if oversized { data.append(Data(count: Stream.maximumInputBytes + 1)) }
                return data
            },
            send: { _ in },
            sendEnd: { data in
                #expect((try? Stream.decode(data).frame) == .end(.init(reason: .protocolError)))
            }, delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { buffer in
                _ = buffer.beginGeneration()
                ready.resolve(.success(()))
                _ = try? await CompanionNetworkOperation<Void>().wait {}
            })
        #expect(reason == .protocolError)
    }

    @Test func oversizedWireLengthEndsStreamWithProtocolError() async {
        let reason = await Relay.run(
            socketPath: "unused", paneID: UUID(), targetVersion: UUID(), grid: .init(rows: 24, cols: 80),
            buffer: Relay.Buffer(), phoneFrames: { throw LocalAPIError.requestTooLarge },
            send: { _ in }, sendEnd: { _ in }, delay: { try await ContinuousClock().sleep(for: $0) },
            produce: { _ in _ = try? await CompanionNetworkOperation<Void>().wait {} })
        #expect(reason == .protocolError)
    }

    @Test func departedLeaderDoesNotStopMonitoringBeforeDaemonDetach() {
        let driving = CompanionTerminalDriving()
        let pane = UUID(), stream = UUID()
        driving.register(paneID: pane, sessionName: "same", attachmentID: 42, streamID: stream, deviceName: "iPhone", disconnect: {})
        driving.remove(streamID: stream, paneID: pane)
        driving.didObserve(paneID: pane, sessionName: "same", leader: 42)
        #expect(driving.monitoredSessions[pane] == "same")
        driving.didObserve(paneID: pane, sessionName: "same", leader: 0)
        #expect(driving.monitoredSessions[pane] == "same")
        driving.didObserve(paneID: pane, sessionName: "same", leader: 99)
        #expect(driving.monitoredSessions[pane] == nil)
    }

    @Test func bannerDisconnectOnlyEndsTheMatchingStream() {
        let driving = CompanionTerminalDriving()
        let pane = UUID(), first = UUID(), second = UUID()
        var disconnected: [UUID] = []
        for (id, stream) in [(UInt64(42), first), (UInt64(43), second)] {
            driving.register(paneID: pane, sessionName: "same", attachmentID: id, streamID: stream, deviceName: "iPhone") {
                disconnected.append(stream)
            }
        }
        #expect(driving.device(paneID: pane, sessionName: "other", leader: 42) == nil)
        #expect(driving.device(paneID: pane, sessionName: "same", leader: 0) == nil)
        driving.device(paneID: pane, sessionName: "same", leader: 42)?.disconnect()
        #expect(disconnected == [first])
        driving.remove(streamID: first, paneID: pane)
        #expect(driving.device(paneID: pane, sessionName: "same", leader: 42) == nil)
        #expect(driving.device(paneID: pane, sessionName: "same", leader: 43)?.streamID == second)
    }

}
