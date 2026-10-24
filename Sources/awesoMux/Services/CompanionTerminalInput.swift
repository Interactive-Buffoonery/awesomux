import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import Foundation

struct CompanionTerminalAuthorization {
    typealias Stream = CompanionTerminalStream
    let lease: LocalAPIAuthorizationLease
    let accepted: Stream.Accepted
    let local: Bool

    static func accepted(inputAllowed: Bool, local: Bool) -> Stream.Accepted {
        if !local { return .init(role: .watch, watchReason: .remotePane) }
        return inputAllowed ? .init(role: .interactive) : .init(role: .watch, watchReason: .inputOff)
    }

    func validate(_ current: LocalAPIAuthorizationLease, targetIsCurrent: Bool) throws {
        guard current.connectionID == lease.connectionID,
            current.connectionRevision == lease.connectionRevision,
            current.globalRevision == lease.globalRevision,
            current.terminalWatchScope != nil,
            current.terminalWatchScope == lease.terminalWatchScope
        else { throw Stream.EndReason.revoked }
        guard targetIsCurrent else { throw Stream.EndReason.paneUnavailable }
        guard Self.accepted(inputAllowed: current.terminalInputAllowed, local: local).role == accepted.role
        else { throw Stream.EndReason.roleChanged }
    }
}

extension CompanionTerminalWatchRelay {
    /// Only these two typed operations may carry device intent to the daemon.
    struct InputState {
        let role: Stream.Role
        private(set) var grid: Stream.Grid
        private var attachment: (id: UInt64, revision: UInt64)?

        init(role: Stream.Role, grid: Stream.Grid) {
            self.role = role
            self.grid = grid
        }

        mutating func attach(id: UInt64, revision: UInt64) { attachment = (id, revision) }

        mutating func message(_ frame: Stream.Frame) throws -> Data? {
            guard role == .interactive, let attachment else { throw Stream.EndReason.protocolError }
            let tag: ZmxTag
            var bytes = Data()
            switch frame {
            case .grid(let requested):
                try validate(requested)
                grid = requested
                return nil
            case .claim(let claim):
                try validate(claim.grid)
                grid = claim.grid
                tag = .takeOver
            case .input(_, let input):
                guard !input.isEmpty, input.count <= Stream.maximumInputBytes else { throw Stream.EndReason.protocolError }
                tag = .userBatch
                bytes = input
            default:
                throw Stream.EndReason.protocolError
            }
            var payload = Data()
            for value in [attachment.id, attachment.revision] {
                withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
            }
            return zmxMessage(tag, payload + gridPayload(grid) + bytes)
        }

        private func validate(_ grid: Stream.Grid) throws {
            guard (1...1000).contains(grid.rows), (1...1000).contains(grid.cols) else { throw Stream.EndReason.protocolError }
        }
    }

    @MainActor
    final class InputForwarder {
        typealias Submit = @MainActor (Data, @escaping @MainActor () throws -> Void) async throws -> Void
        private let role: Stream.Role
        private let initialGrid: Stream.Grid
        private let buffer: Buffer
        private let validate: @MainActor () throws -> Void
        private var state: InputState
        private var generation: UInt32?
        private var submit: Submit?
        private var highestSequence: UInt64?
        private var resync: @MainActor () -> Void = {}

        init(role: Stream.Role, grid: Stream.Grid, buffer: Buffer, validate: @escaping @MainActor () throws -> Void = {}) {
            self.role = role
            initialGrid = grid
            self.buffer = buffer
            self.validate = validate
            state = InputState(role: role, grid: grid)
        }

        func install(
            generation: UInt32, id: UInt64, revision: UInt64,
            resync: @escaping @MainActor () -> Void = {}, submit: @escaping Submit
        ) {
            state = InputState(role: role, grid: initialGrid)
            state.attach(id: id, revision: revision)
            self.generation = generation
            self.submit = submit
            self.resync = resync
            highestSequence = nil
        }

        func detach(generation: UInt32) {
            guard self.generation == generation else { return }
            self.generation = nil
            submit = nil
            resync = {}
            highestSequence = nil
        }

        func receive(_ data: Data) async throws {
            guard data.count >= Stream.headerBytes else { throw Stream.EndReason.protocolError }
            let incoming = data.dropFirst().prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard buffer.acceptsInput(generation: incoming) else { return }
            let decoded: (frame: Stream.Frame, generation: UInt32)
            do { decoded = try Stream.decode(data) } catch { throw Stream.EndReason.protocolError }
            try validate()
            if case .end(let end) = decoded.frame, end.reason == .closed { throw Stream.EndReason.closed }
            switch decoded.frame {
            case .input, .claim, .grid:
                guard role == .interactive else { throw Stream.EndReason.protocolError }
            default:
                throw Stream.EndReason.protocolError
            }
            guard generation == incoming, let submit else { return }
            guard let message = try state.message(decoded.frame) else { return }
            do {
                try await submit(message) { [self] in
                    try validate()
                    guard generation == incoming, buffer.acceptsInput(generation: incoming) else { throw CancellationError() }
                }
            } catch is CancellationError {
                guard !Task.isCancelled, generation != incoming || !buffer.acceptsInput(generation: incoming) else {
                    throw CancellationError()
                }
                return
            }
            // A completed old socket write never acknowledges input in a new generation.
            guard generation == incoming, buffer.acceptsInput(generation: incoming) else { return }
            if case .input(let sequence, _) = decoded.frame {
                let highest = max(sequence, highestSequence ?? sequence)
                highestSequence = highest
                if buffer.enqueue(.ack(.init(sequence: highest)), generation: incoming) == .overflow {
                    resync()
                }
            }
        }
    }
}
