import Foundation

/// Runtime limits for remote-agent bridge requests, handshakes, and delivery.
public enum BridgeTunables {
    /// Spec ("Permission lifecycle"): "Backpressure: the map is capped at
    /// 4 entries per attach."
    public static let pendingRequestCap = 4

    /// Spec ("Permission lifecycle"): "Timeout default: 120 s, fail-closed
    /// to deny" — the app's own clamp, applied as
    /// `min(request.expiresAt, permissionTimeoutClamp)`.
    public static let permissionTimeoutClamp: TimeInterval = 120

    /// Spec ("Handshake and version negotiation"): "a connection that has
    /// not delivered a valid `hello` within 5 s of accept is closed."
    public static let helloDeadline: TimeInterval = 5

    /// App-side cap on VALIDATED frames queued between the connection actor
    /// and its MainActor consumers. Every other resource has a bound — 4
    /// pending requests, 64 KiB lines, 1+1 connections — but an unbounded
    /// delivery stream let an authenticated-but-hostile helper grow app
    /// memory with perfectly valid frames. Frames are control-plane
    /// (status/rename/permission), legitimately tens outstanding at worst; a
    /// helper that fills 256 is broken or hostile, and the connection is
    /// closed — the same posture as the reader's unterminated-line close.
    public static let frameQueueCap = 256

    /// Maximum decision sends admitted concurrently for one connection.
    public static let outboundDecisionCap = 8

    /// A peer that does not read decisions loses the connection rather than
    /// retaining writers indefinitely.
    public static let outboundWriteDeadline: TimeInterval = 5

    /// After the permission FIFO advances to a new head, user decisions are
    /// ignored for this interval so a double-click / second key event cannot
    /// authorize the *next* prompt that just slid into the same Allow button.
    public static let permissionDecisionArmDelay: TimeInterval = 0.35
}
