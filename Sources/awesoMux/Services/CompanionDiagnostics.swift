import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import Foundation
import Network
import os

/// Separate from relay state so diagnostics cannot change termination decisions.
final class CompanionDiagnostics: Sendable {
    static let listener = Logger(subsystem: "com.interactivebuffoonery.awesomux", category: "companion.listener")
    static let watch = Logger(subsystem: "com.interactivebuffoonery.awesomux", category: "companion.watch")
    static let transport = Logger(subsystem: "com.interactivebuffoonery.awesomux", category: "companion.transport")
    let id: UUID
    private let started = ContinuousClock.now
    private struct State {
        var cause: (origin: String, phase: String, reason: String)?
        var ended = false
        var frames = 0
        var bytes = 0
        var lastFrame: ContinuousClock.Instant?
        var lastHeartbeat: ContinuousClock.Instant?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(id: UUID = UUID()) { self.id = id }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    func close(origin: String, phase: String, reason: String) {
        state.withLock {
            if $0.cause == nil { $0.cause = (origin, phase, reason) }
        }
    }

    func wrote(bytes: Int, heartbeat: Bool = false) {
        state.withLock {
            $0.frames += 1
            $0.bytes += bytes
            $0.lastFrame = .now
            if heartbeat { $0.lastHeartbeat = .now }
        }
    }

    func end(generation: UInt32, pendingBytes: Int) {
        let snapshot = state.withLock { value -> State? in
            guard !value.ended else { return nil }
            value.ended = true
            return value
        }
        guard let snapshot else { return }
        let now = ContinuousClock.now
        let cause = snapshot.cause ?? ("relay", "cleanup", "closed")
        let frameAge = snapshot.lastFrame.map { Self.milliseconds(now - $0) } ?? -1
        let heartbeatAge = snapshot.lastHeartbeat.map { Self.milliseconds(now - $0) } ?? -1
        Self.watch.notice(
            "watch_end watch_id=\(self.id, privacy: .public) origin=\(cause.0, privacy: .public) phase=\(cause.1, privacy: .public) reason=\(cause.2, privacy: .public) elapsed_ms=\(Self.milliseconds(now - self.started)) generation=\(generation) frames=\(snapshot.frames) wire_bytes=\(snapshot.bytes) pending_bytes=\(pendingBytes) last_frame_ms=\(frameAge) last_heartbeat_ms=\(heartbeatAge)"
        )
    }

    static func reason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let value = error as? CompanionTerminalStream.EndReason { return value.rawValue }
        if let value = error as? LocalAPIError { return value.rawValue }
        if let value = error as? CompanionPairingError { return String(describing: value) }
        if error is NWError { return "network_error" }
        return "unclassified"
    }

    static func networkError(_ error: NWError, phase: String) {
        let kind: String
        let code: Int32
        switch error {
        case .posix(let value): kind = "posix"; code = value.rawValue
        case .dns(let value): kind = "dns"; code = value
        case .tls(let value): kind = "tls"; code = value
        @unknown default: kind = "unknown"; code = 0
        }
        transport.error("network_error phase=\(phase, privacy: .public) kind=\(kind, privacy: .public) code=\(code)")
    }
}
