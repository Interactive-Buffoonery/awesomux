import Foundation

/// A parsed lifecycle or foreground-process event from the amx status file.
///
/// The daemon writes one JSONL object per line; a kqueue watcher feeds new
/// bytes to `parseLines(_:expectedToken:)` which returns the events it can
/// fully decode. Lines that are malformed, wrong-token, or incomplete (no
/// trailing newline) are silently dropped — this is intentional because
/// kqueue can fire mid-write. Authenticated foreground envelopes with malformed
/// typed payloads are instead surfaced as invalid so consumers clear evidence.
///
/// The wire shapes are:
/// ```
/// {"event":"attached","token":"…","created":<bool>,"daemon_pid":<int>,
///  "daemon_created_at":<int>,"daemon_incarnation":<uint>,"session":"…","ts":<int>}
///
/// {"event":"foreground-process","token":"…","daemon_pid":<int>,
///  "daemon_created_at":<int>,"daemon_incarnation":<uint>,
///  "transition_sequence":<uint>,"sample_sequence":<uint>,"state":"…",
///  "process_group_id":<int>,"executable":"…","session":"…","ts":<int>}
///
/// {"event":"session-end","token":"…","reason":"…","code":<int>,
///  "session":"…","ts":<int>}
/// ```
public struct AmxStatusEvent: Equatable {

    // MARK: - Kind

    public enum Kind: Equatable {
        /// The attach completed. `created` is true when the daemon launched a
        /// fresh zmx session, false when it re-attached to an existing one.
        case attached(created: Bool, daemon: AmxDaemonIncarnation)
        /// Current or explicitly degraded foreground evidence sampled from the
        /// persistent daemon's PTY, not the transient attach client's process.
        case foregroundProcess(AmxForegroundProcessPublication)
        /// The authenticated envelope identified a foreground publication, but
        /// its typed payload was malformed. Consumers must clear prior evidence.
        case foregroundProcessInvalid
        /// The session ended. `code` is the shell/daemon exit code.
        case sessionEnd(reason: SessionEndReason, code: Int?)
    }

    // MARK: - Properties

    public let kind: Kind
    /// Opaque attach token shared between the attach command and the status
    /// file; used to reject stale/foreign lines.
    public let token: String
    /// The zmx session ID this event refers to.
    public let session: String

    // MARK: - Parsing

    /// Stateless decoder, hoisted out of `parseLines` so a chatty status feed
    /// doesn't allocate a fresh `JSONDecoder` per kqueue drain. `JSONDecoder`
    /// carries no per-call mutable state, so reusing one decode-only instance is
    /// thread-safe.
    private static let decoder = JSONDecoder()

    /// Parse all *complete* JSONL lines from `buffer`, ignoring any partial
    /// trailing line (no trailing newline) and any line whose `"token"` field
    /// does not equal `expectedToken`.
    ///
    /// - Parameters:
    ///   - buffer: Accumulated bytes from the status file, as a `String`.
    ///   - expectedToken: Token that was written to the status file at attach
    ///     time; lines with a different token are dropped (forgery guard).
    /// - Returns: Successfully decoded events in document order.
    public static func parseLines(_ buffer: String, expectedToken: String) -> [AmxStatusEvent] {
        // A line without a trailing newline is a partial write — ignore it.
        // Splitting on "\n" with a trailing "\n" produces a trailing empty
        // element, so we drop the last component unconditionally and then
        // filter blanks.
        let components = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            // Either empty buffer or a single component with no newline at all.
            // In both cases there are no complete lines.
            return []
        }
        // All components except the last are complete lines (each was
        // terminated by the "\n" that split them off).
        let completeLines = components.dropLast()

        return completeLines.compactMap { line -> AmxStatusEvent? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                let data = trimmed.data(using: .utf8),
                let envelope = try? Self.decoder.decode(Envelope.self, from: data),
                envelope.token == expectedToken
            else { return nil }

            if let event = try? Self.decoder.decode(Wire.self, from: data) {
                return event.asAmxStatusEvent
            }
            guard envelope.event == "foreground-process" else { return nil }
            return AmxStatusEvent(
                kind: .foregroundProcessInvalid,
                token: envelope.token,
                session: ""
            )
        }
    }
}

// MARK: - Codable wire representation

extension AmxStatusEvent {

    private struct Envelope: Decodable {
        let event: String
        let token: String
    }

    /// Internal Codable type that maps the wire shapes.
    ///
    /// Both shapes share `event`, `token`, `session`, and `ts`. The shape-
    /// specific fields are optional so a single struct handles both without
    /// a custom `init(from:)`.
    private struct Wire: Decodable {
        let event: String
        let token: String
        let session: String

        // attached-only fields
        let created: Bool?
        let daemonPid: Int?
        let daemonCreatedAt: Int?
        let daemonIncarnation: UInt64?

        // foreground-process-only fields
        let transitionSequence: UInt64?
        let sampleSequence: UInt64?
        let state: String?
        let processGroupID: Int?
        let executable: String?

        // session-end-only fields
        let reason: String?
        let code: Int?

        enum CodingKeys: String, CodingKey {
            case event, token, session, created, code, reason
            case daemonPid = "daemon_pid"
            case daemonCreatedAt = "daemon_created_at"
            case daemonIncarnation = "daemon_incarnation"
            case transitionSequence = "transition_sequence"
            case sampleSequence = "sample_sequence"
            case processGroupID = "process_group_id"
            case state, executable
        }

        var asAmxStatusEvent: AmxStatusEvent? {
            let kind: Kind
            switch event {
            case "attached":
                // daemon_pid + daemon_created_at together form the incarnation
                // identity used to tell a fresh respawn from a live reconnect.
                // Synthesizing (0,0) for a malformed line would make two such
                // lines compare equal → a false `.reconnect` that never clears
                // stale agent chrome on a respawned shell. Drop the line instead
                // (same as the unknown-event default), forcing the caller to act
                // only on a complete incarnation.
                guard let daemonPid, daemonPid > 0,
                    let daemonCreatedAt, daemonCreatedAt > 0,
                    let daemonIncarnation
                else {
                    return nil
                }
                kind = .attached(
                    created: created ?? false,
                    daemon: AmxDaemonIncarnation(
                        pid: daemonPid,
                        createdAt: daemonCreatedAt,
                        incarnation: daemonIncarnation
                    )
                )
            case "foreground-process":
                if let daemon = daemonIdentity,
                    let transitionSequence,
                    let sampleSequence,
                    let state = foregroundState(
                        transitionSequence: transitionSequence,
                        sampleSequence: sampleSequence
                    )
                {
                    kind = .foregroundProcess(
                        AmxForegroundProcessPublication(
                            daemon: daemon,
                            transitionSequence: transitionSequence,
                            sampleSequence: sampleSequence,
                            state: state
                        )
                    )
                } else {
                    kind = .foregroundProcessInvalid
                }
            case "session-end":
                // Preserve a missing/absent `code` as nil rather than defaulting
                // to 0 — 0 is the clean-exit sentinel, and the end policy treats an
                // unknown remote exit code as abnormal (.error). Collapsing absent
                // to 0 would make a code-less remote session-end read as a clean
                // exit and silently close the workgroup (INT-769 safe-default).
                kind = .sessionEnd(
                    reason: SessionEndReason(wireString: reason ?? ""),
                    code: code
                )
            default:
                // Unknown event type — drop it instead of synthesizing a
                // spurious session-end that could trigger unwanted respawn.
                return nil
            }
            return AmxStatusEvent(kind: kind, token: token, session: session)
        }

        private var daemonIdentity: AmxDaemonIncarnation? {
            guard let daemonPid, daemonPid > 0,
                let daemonCreatedAt, daemonCreatedAt > 0,
                let daemonIncarnation, daemonIncarnation > 0
            else {
                return nil
            }
            return AmxDaemonIncarnation(
                pid: daemonPid,
                createdAt: daemonCreatedAt,
                incarnation: daemonIncarnation
            )
        }

        private func foregroundState(
            transitionSequence: UInt64,
            sampleSequence: UInt64
        ) -> AmxForegroundProcessPublication.State? {
            guard transitionSequence <= sampleSequence,
                let state,
                let processGroupID,
                let executable
            else {
                return nil
            }

            switch state {
            case "foreground":
                guard transitionSequence > 0,
                    sampleSequence > 0,
                    processGroupID > 0,
                    !executable.isEmpty,
                    executable.utf8.count <= 256,
                    !executable.unicodeScalars.contains(where: { $0.value < 0x20 })
                else {
                    return nil
                }
                return .foreground(processGroupID: processGroupID, executable: executable)
            case "no-foreground":
                guard transitionSequence > 0,
                    sampleSequence > 0,
                    processGroupID == 0,
                    executable.isEmpty
                else {
                    return nil
                }
                return .noForeground
            case "unavailable":
                guard transitionSequence > 0,
                    sampleSequence > 0,
                    processGroupID == 0,
                    executable.isEmpty
                else {
                    return nil
                }
                return .unavailable
            case "malformed":
                guard processGroupID == 0, executable.isEmpty else { return nil }
                return .malformed
            case "stale":
                guard processGroupID == 0, executable.isEmpty else { return nil }
                return .stale
            default:
                return nil
            }
        }
    }
}

// MARK: - SessionEndReason wire mapping

private extension SessionEndReason {
    /// Map the wire `"reason"` string to `SessionEndReason`.
    /// Unrecognized strings map to `.unknown` rather than crashing.
    init(wireString: String) {
        switch wireString {
        case "daemon-died": self = .daemonDied
        case "detached":    self = .detached
        case "shell-exit":  self = .shellExit
        default:            self = .unknown
        }
    }
}
