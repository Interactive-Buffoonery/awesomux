import Foundation

/// Turns raw bytes read off a `awesomux-bridge-v1` connection into decoded
/// frames plus a connection-lifecycle action.
///
/// Pure state machine: no I/O, no wall-clock reads. `now` is injected so the
/// partial-line deadline is testable without a real clock, mirroring
/// `AmxStatusFileWatcher.consume`'s split between a stateless pure core and
/// the stateful watcher that feeds it real bytes/time.
///
/// The parse contract requires partial-line hold, the exact 65,536-byte line
/// cap, and a 10 s partial-frame deadline. Forwards and sockets are
/// connection-scoped resources —
/// this type is the connection's byte-level half; everything about *when* a
/// connection may accept non-hello frames, token/proto/session validation for
/// `hello` itself, and hello-nack-vs-plain-close semantics is the connection
/// actor's job (C2), not this reader's).
public enum BridgeFrameReader {

    /// Held partial-line bytes plus the moment they started waiting for a
    /// terminating newline. The initializer enforces the invariant that
    /// `startedAt` is `nil` exactly when `bytes` is empty — nothing waiting
    /// means nothing to time out. Without that normalization, a caller bug
    /// that pairs empty bytes with a stale date would make `consume` fire a
    /// spurious deadline close on a connection with nothing pending.
    public struct PendingTail: Sendable, Equatable {
        public var bytes: Data
        public var startedAt: Date?

        public static let empty = PendingTail(bytes: Data(), startedAt: nil)

        public init(bytes: Data, startedAt: Date?) {
            self.bytes = bytes
            self.startedAt = bytes.isEmpty ? nil : startedAt
        }
    }

    /// One decoded line. Handshake frames (`hello`/`hello-ack`/`hello-nack`)
    /// and regular envelope frames ride the same JSONL wire but validate
    /// against different schemas — `BridgeHandshake` has no `v` field and no
    /// token comparison of its own (see its doc comment). This reader decodes
    /// both; it has no notion of "have we handshaked yet", so a caller that
    /// wants to enforce "nothing but hello until a valid hello" (the spec's
    /// Handshake section) applies that gating on top of the decoded stream.
    public enum Frame: Sendable, Equatable {
        case handshake(BridgeHandshake)
        case envelope(BridgeEnvelope)
    }

    /// What the connection should do after this `consume` call.
    public enum Action: Sendable, Equatable {
        case none
        case close(reason: CloseReason)
    }

    public enum CloseReason: Sendable, Equatable {
        /// The accumulation buffer holds > 65,535 bytes with no newline —
        /// an endpoint streaming an unterminated frame is broken or hostile,
        /// and holding its buffer indefinitely is a resource hostage.
        ///
        /// A *complete* (newline-terminated) line over the cap is a drop,
        /// not a close: the spec scopes the close to the no-newline
        /// accumulation case, and once the newline arrived there is no
        /// hostage — just an oversized frame, dropped like any other
        /// malformed line.
        case unterminatedLineTooLarge
        /// A partial line has been waiting longer than the 10 s deadline.
        case partialLineDeadline
    }

    /// Exact line cap from the spec: a complete line, including its
    /// terminating newline, must be ≤ this many bytes.
    static let maximumLineByteCount = 65_536

    /// Partial-line age limit before the connection is treated as hostile/broken.
    public static let partialLineDeadline: TimeInterval = 10

    /// - Parameters:
    ///   - data: Freshly read bytes from the connection.
    ///   - pendingTail: Partial-line bytes (and their start time) carried
    ///     over from the previous call.
    ///   - now: Injected clock reading, compared against `pendingTail.startedAt`.
    ///     Must be non-decreasing across calls for one connection — this
    ///     deadline math cannot defend against a wall clock stepping
    ///     backwards, so the caller should derive `now` from a monotonic
    ///     source (or accept that an NTP step can stretch the 10 s bound).
    ///   - expectedToken: Per-attach forgery token; envelope frames with a
    ///     different token are dropped (constant-time compare, per the
    ///     spec's Security analysis).
    ///   - expectedSession: The `AWESOMUX_BRIDGE_SESSION` correlation id this
    ///     connection is bound to; envelope frames naming another session
    ///     are dropped. (Handshake frames are not filtered here — `hello`
    ///     token/session validation closes the connection instead of
    ///     dropping, which is the connection actor's call.)
    public static func consume(
        _ data: Data,
        pendingTail: PendingTail,
        now: Date,
        expectedToken: String,
        expectedSession: String
    ) -> (frames: [Frame], tail: PendingTail, action: Action) {
        let buffer: Data
        if pendingTail.bytes.isEmpty {
            buffer = data
        } else {
            var combined = pendingTail.bytes
            combined.append(data)
            buffer = combined
        }

        guard !buffer.isEmpty else {
            return (frames: [], tail: .empty, action: .none)
        }

        guard let lastNewlineIndex = buffer.lastIndex(of: 0x0A) else {
            // No newline anywhere — the whole buffer is one partial line.
            if buffer.count >= maximumLineByteCount {
                return (frames: [], tail: .empty, action: .close(reason: .unterminatedLineTooLarge))
            }
            // The deadline is evaluated only while the line is still
            // incomplete: bytes in *this* call that deliver the newline are
            // processed above, never discarded by a close. The deadline
            // defends against a held-open buffer (a resource hostage), and
            // a line that just completed holds nothing — closing anyway
            // would turn a slow-but-delivered permission decision into a
            // spurious fail-closed deny. A line already in progress keeps
            // its original start time (its age is what the deadline
            // measures); a brand-new partial line starts its clock now.
            let startedAt = pendingTail.startedAt ?? now
            if now.timeIntervalSince(startedAt) > partialLineDeadline {
                return (frames: [], tail: .empty, action: .close(reason: .partialLineDeadline))
            }
            return (frames: [], tail: PendingTail(bytes: buffer, startedAt: startedAt), action: .none)
        }

        let completeEnd = buffer.index(after: lastNewlineIndex)
        let completeSlice = buffer[buffer.startIndex..<completeEnd]
        let remainder = Data(buffer[completeEnd...])

        // Decode whatever completed first, even if the trailing remainder
        // (below) turns out to be an oversized unterminated line — the
        // completed lines already arrived intact and are worth delivering.
        let frames = Self.decodeLines(in: completeSlice, expectedToken: expectedToken, expectedSession: expectedSession)

        if remainder.count >= maximumLineByteCount {
            return (frames: frames, tail: .empty, action: .close(reason: .unterminatedLineTooLarge))
        }

        let newTail = remainder.isEmpty ? PendingTail.empty : PendingTail(bytes: remainder, startedAt: now)
        return (frames: frames, tail: newTail, action: .none)
    }

    /// `slice` always ends with the newline that terminated its last line
    /// (by construction from `consume`), so splitting on `0x0A` produces one
    /// trailing empty component to drop — the same shape
    /// `AmxStatusEvent.parseLines` uses for its `String`-based buffer.
    private static func decodeLines(in slice: Data, expectedToken: String, expectedSession: String) -> [Frame] {
        let components = slice.split(separator: 0x0A, omittingEmptySubsequences: false)
        return components.dropLast().compactMap { line in
            Self.decodeLine(line, expectedToken: expectedToken, expectedSession: expectedSession)
        }
    }

    /// Drops (never closes) a line that's oversized, empty, unparseable,
    /// names an unknown type/`v`, or — for envelope frames only — carries
    /// the wrong token or session. Per the spec's parse contract this is a
    /// silent drop; the connection stays open.
    private static func decodeLine(
        _ lineWithoutNewline: Data.SubSequence,
        expectedToken: String,
        expectedSession: String
    ) -> Frame? {
        // +1 restores the newline byte `split` consumed, matching the spec's
        // "including its terminating newline" line-cap wording.
        guard !lineWithoutNewline.isEmpty, lineWithoutNewline.count + 1 <= maximumLineByteCount else {
            return nil
        }
        let jsonData = Data(lineWithoutNewline)

        if let handshake = BridgeHandshake.parse(data: jsonData) {
            return .handshake(handshake)
        }
        guard let envelope = BridgeEnvelope.parse(data: jsonData),
              constantTimeEquals(envelope.token, expectedToken),
              envelope.session == expectedSession
        else {
            return nil
        }
        return .envelope(envelope)
    }

    /// Constant-time string equality for the per-attach forgery token — the
    /// spec's Security analysis names constant-time token compare as a frame
    /// validation requirement, and Swift's `String ==` short-circuits on the
    /// first differing byte. XOR-accumulating over the full length leaks
    /// only the lengths, never a matching-prefix timing gradient. (The
    /// `session` compare above stays plain `==`: it's a non-secret
    /// correlation id, not a credential.)
    ///
    /// `package` (not `internal`) so `BridgeConnectionSupervisor`'s `hello`
    /// token check — a validation this reader deliberately doesn't perform,
    /// see the type doc comment — reuses this exact compare instead of a
    /// second hand-rolled one that could subtly diverge.
    package static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}
