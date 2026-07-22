import Foundation
import UnicodeHygiene

/// A decoded `awesomux-bridge-v1` frame — the versioned envelope every
/// non-handshake message on the remote agent bridge socket carries.
///
/// Decode drops the frame (`nil`) rather than coercing an unrecognized
/// `type`/`v`, an oversized line, or a hostile free-text field into
/// something plausible — the same discipline `AmxStatusEvent` uses for the
/// local side channel. Every helper frame is untrusted input (a compromised
/// or buggy remote helper), so a synthesized fallback here could forge an
/// agent-status update or a permission decision.
public struct BridgeEnvelope: Sendable, Equatable {
    public static let supportedVersion = 1

    public let token: String
    public let session: String
    public let id: String
    public let ts: Double
    public let message: BridgeMessage

    public init(token: String, session: String, id: String, ts: Double, message: BridgeMessage) {
        self.token = token
        self.session = session
        self.id = id
        self.ts = ts
        self.message = message
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // MARK: - Decoding

    public static func parse(line: String) -> BridgeEnvelope? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return parse(data: data)
    }

    /// Single-decode parse. An earlier version decoded a minimal `Header`
    /// (just `v`/`type`) first so the per-type byte cap could be checked
    /// before the full `Wire` decode — but `JSONDecoder` tokenizes the
    /// *whole* input buffer regardless of how few fields the target declares,
    /// so that first decode was a second full tokenization pass buying almost
    /// nothing. The raw `data.count` check runs first against the largest cap
    /// any type can have, so a hostile multi-megabyte line is rejected before
    /// `JSONDecoder` ever runs; the tighter per-type cap is then checked on
    /// the decoded `type` *before* `asBridgeMessage`'s free-text validation
    /// (the genuinely expensive, security-sensitive step) ever touches an
    /// oversized-for-its-type frame. `Wire`'s own decode is only tokenization,
    /// already bounded by the raw check, so it is safe to run before the
    /// per-type cap gate.
    public static func parse(data: Data) -> BridgeEnvelope? {
        guard data.count <= BridgeMessage.maximumPossibleLineByteCount,
            let wire = try? decoder.decode(Wire.self, from: data),
            wire.v == supportedVersion,
            let cap = BridgeMessage.maximumLineByteCount(forWireType: wire.type),
            data.count <= cap,
            let message = wire.asBridgeMessage
        else {
            return nil
        }

        return BridgeEnvelope(token: wire.token, session: wire.session, id: wire.id, ts: wire.ts, message: message)
    }

    // MARK: - Encoding

    /// Serializes back to the flat single-line JSON shape the spec defines.
    /// Used for app → helper frames (`permission-decision`) and round-trip
    /// tests; production frame writes go through this so the wire shape
    /// can't drift from `parse`'s expectations.
    ///
    /// The payload structs (`PermissionRequest`, `HandoffNotify`, etc.) have
    /// plain public initializers with no validation of their own — nothing
    /// stops app code from constructing, say, a `title` that's too long or
    /// carries a bidi override, and encoding it. Re-decoding the freshly
    /// encoded line and asserting it comes back equal to `self` is the
    /// cheapest way to guarantee `encodedLine()` never emits a frame that
    /// `parse` would then drop, without duplicating every validation rule
    /// a second time on the encode path.
    public func encodedLine() throws -> String {
        let data = try Self.encoder.encode(Wire(envelope: self))
        let line = String(decoding: data, as: UTF8.self)
        guard Self.parse(line: line) == self else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "BridgeEnvelope failed its own round-trip validation")
            )
        }
        return line
    }
}

// MARK: - Message payloads

/// The six bridge message payloads. Cases carry only the fields the spec
/// documents for that `type` — flat on the same JSON object as the envelope,
/// never nested.
///
/// Adding a case here is a guaranteed compile error at `wireType` and
/// `Wire.init(envelope:)` (both switch exhaustively on this enum) until
/// both are updated — but `Wire.asBridgeMessage`'s decode switch is keyed
/// on the wire's `String` `type`, which Swift cannot exhaustively check.
/// Forgetting to add that decode branch compiles clean and silently drops
/// every frame of the new type as "unrecognized type" forever; there's no
/// compiler backstop for that half of adding a seventh case.
public enum BridgeMessage: Sendable, Equatable {
    case agentStatus(AgentStatus)
    case paneRename(title: String)
    case handoffNotify(HandoffNotify)
    case permissionRequest(PermissionRequest)
    case permissionDecision(PermissionDecision)
    case permissionResolved(PermissionResolved)

    /// Wire `type` discriminator.
    var wireType: String {
        switch self {
        case .agentStatus: "agent-status"
        case .paneRename: "pane-rename"
        case .handoffNotify: "handoff-notify"
        case .permissionRequest: "permission-request"
        case .permissionDecision: "permission-decision"
        case .permissionResolved: "permission-resolved"
        }
    }

    /// Per-type raw-line byte cap from the spec's Message types section.
    /// `nil` for any unrecognized `type` — the caller treats that as
    /// "unknown type, drop the frame", not "no cap".
    static func maximumLineByteCount(forWireType type: String) -> Int? {
        switch type {
        case "agent-status", "pane-rename", "permission-resolved":
            4 * 1024
        case "handoff-notify", "permission-request", "permission-decision":
            8 * 1024
        default:
            nil
        }
    }

    /// The largest cap any known type has (currently the 8 KiB bucket).
    /// `parse(data:)` checks the raw byte count against this *before* any
    /// `JSONDecoder` work — a single oversized line is rejected up front, and
    /// the tighter per-type cap (looked up from the decoded `type`) then
    /// gates the free-text validation. Derived from the two buckets above so
    /// the two numbers can't drift apart.
    static let maximumPossibleLineByteCount = max(4 * 1024, 8 * 1024)

    /// Free-text field length caps. The spec bounds only the whole-frame
    /// KiB size, not individual fields, so these two are the only numeric
    /// per-field caps this type enforces — and both cite a *pre-existing*
    /// repo convention rather than a number invented for this task:
    /// `title` reuses the app's real pane-title limit, `path` reuses
    /// `AmxBackend.parseCwdOutput`'s remote-path bound. `tool`/`summary`/
    /// `target` deliberately do NOT get an extra invented cap here — an
    /// earlier draft added 256/512/2048-byte limits for them, but the spec
    /// never publishes those numbers, so a spec-compliant helper sending
    /// an otherwise-valid ≤8 KiB permission frame could get silently
    /// dropped for exceeding a cap this repo made up. The type's own
    /// per-type byte cap (`maximumLineByteCount`, already enforced before
    /// full decode) is the real, spec-mandated bound on those three;
    /// scalar-safety (no NUL/bidi/zero-width) still applies to all of them.
    public enum FieldLimit {
        public static let title = 200  // same semantic field as the local pane title.
        static let path = 1024  // matches AmxBackend.parseCwdOutput's remote-path bound.
    }
}

public struct AgentStatus: Sendable, Equatable {
    public var source: AgentRuntimeSource
    public var kind: AgentKind?
    public var execution: AgentExecutionState?
    public var attentionReason: AttentionReason?
    public var phase: AgentRuntimePhase?
    public var providerSessionID: String?
    public var eventID: String?

    public init(
        source: AgentRuntimeSource,
        kind: AgentKind? = nil,
        execution: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        phase: AgentRuntimePhase? = nil,
        providerSessionID: String? = nil,
        eventID: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.execution = execution
        self.attentionReason = attentionReason
        self.phase = phase
        self.providerSessionID = providerSessionID
        self.eventID = eventID
    }
}

public struct HandoffNotify: Sendable, Equatable {
    public enum MediaKind: String, Sendable, Equatable, Codable {
        case image
        case file
    }

    public var path: String
    public var name: String?
    public var mediaKind: MediaKind
    public var bytes: Int?

    public init(path: String, name: String? = nil, mediaKind: MediaKind, bytes: Int? = nil) {
        self.path = path
        self.name = name
        self.mediaKind = mediaKind
        self.bytes = bytes
    }
}

public struct PermissionRequest: Sendable, Equatable {
    public var tool: String
    public var target: String
    public var summary: String?
    public var expiresAt: Double

    public init(tool: String, target: String, summary: String? = nil, expiresAt: Double) {
        self.tool = tool
        self.target = target
        self.summary = summary
        self.expiresAt = expiresAt
    }
}

public struct PermissionDecision: Sendable, Equatable {
    public enum Decision: String, Sendable, Equatable, Codable {
        case allow
        case deny
    }

    public enum Scope: String, Sendable, Equatable, Codable {
        case once
        case session
    }

    public var inReplyTo: String
    public var decision: Decision
    public var scope: Scope
    public var target: String

    public init(inReplyTo: String, decision: Decision, scope: Scope, target: String) {
        self.inReplyTo = inReplyTo
        self.decision = decision
        self.scope = scope
        self.target = target
    }
}

public struct PermissionResolved: Sendable, Equatable {
    /// `connection-lost`/`overflow` are spelled with a hyphen on the wire;
    /// `agentCancelled` maps from `agent-cancelled` the same way
    /// `AgentRuntimePhase.openDocument` maps from `open-document`.
    public enum Reason: String, Sendable, Equatable, Codable {
        case expired
        case agentCancelled = "agent-cancelled"
        case connectionLost = "connection-lost"
        case overflow
    }

    public var inReplyTo: String
    public var reason: Reason

    public init(inReplyTo: String, reason: Reason) {
        self.inReplyTo = inReplyTo
        self.reason = reason
    }
}

// MARK: - Wire representation

extension BridgeEnvelope {
    /// Flat Codable wire shape for every message type, mirroring
    /// `AmxStatusEvent.Wire`: one struct, shape-specific fields optional,
    /// so a single decode/encode path handles all six types without a
    /// hand-written `init(from:)`/`encode(to:)` per case.
    fileprivate struct Wire: Codable {
        var v: Int
        var type: String
        var token: String
        var session: String
        var id: String
        var ts: Double

        // agent-status
        var source: AgentRuntimeSource?
        var kind: AgentKind?
        var execution: AgentExecutionState?
        var attentionReason: AttentionReason?
        var phase: AgentRuntimePhase?
        var providerSessionID: String?
        var eventID: String?

        // pane-rename
        var title: String?

        // handoff-notify
        var path: String?
        var name: String?
        var mediaKind: HandoffNotify.MediaKind?
        var bytes: Int?

        // permission-request
        var tool: String?
        var target: String?
        var summary: String?
        var expiresAt: Double?

        // permission-decision / permission-resolved
        var inReplyTo: String?
        var decision: PermissionDecision.Decision?
        var scope: PermissionDecision.Scope?
        var reason: PermissionResolved.Reason?

        init(envelope: BridgeEnvelope) {
            v = BridgeEnvelope.supportedVersion
            type = envelope.message.wireType
            token = envelope.token
            session = envelope.session
            id = envelope.id
            ts = envelope.ts

            switch envelope.message {
            case .agentStatus(let payload):
                source = payload.source
                kind = payload.kind
                execution = payload.execution
                attentionReason = payload.attentionReason
                phase = payload.phase
                providerSessionID = payload.providerSessionID
                eventID = payload.eventID
            case .paneRename(let value):
                title = value
            case .handoffNotify(let payload):
                path = payload.path
                name = payload.name
                mediaKind = payload.mediaKind
                bytes = payload.bytes
            case .permissionRequest(let payload):
                tool = payload.tool
                target = payload.target
                summary = payload.summary
                expiresAt = payload.expiresAt
            case .permissionDecision(let payload):
                inReplyTo = payload.inReplyTo
                decision = payload.decision
                scope = payload.scope
                target = payload.target
            case .permissionResolved(let payload):
                inReplyTo = payload.inReplyTo
                reason = payload.reason
            }
        }
    }
}

extension BridgeEnvelope.Wire {
    /// Validates and builds the typed payload for `type`. Returns `nil` —
    /// never a coerced/best-effort payload — when a required field is
    /// missing, a free-text field fails scalar-safety or its length cap, or
    /// `type` itself is unrecognized (belt-and-braces: `parse(data:)`
    /// already rejected unknown types via the byte-cap lookup, but this
    /// keeps the builder correct if ever called directly).
    var asBridgeMessage: BridgeMessage? {
        switch type {
        case "agent-status":
            guard let source else { return nil }
            return .agentStatus(
                AgentStatus(
                    source: source,
                    kind: kind,
                    execution: execution,
                    attentionReason: attentionReason,
                    phase: phase,
                    providerSessionID: providerSessionID,
                    eventID: eventID
                )
            )

        case "pane-rename":
            // An absent title is dropped; empty string is the valid
            // "reset to live terminal title" request, so `nil`-vs-"" is
            // load-bearing and must not collapse to a single default.
            guard let title,
                let validated = Self.validatedFreeText(title, maxLength: BridgeMessage.FieldLimit.title)
            else { return nil }
            return .paneRename(title: validated)

        case "handoff-notify":
            guard let path,
                let validatedPath = Self.validatedRemotePath(path),
                let mediaKind
            else { return nil }
            // `name` is advisory display text (a basename), but it's still
            // shown to the user next to the path — a bidi override here is
            // the classic RLO filename-spoofing trick (a name that renders
            // as "invoice.png" but is actually "invoice[RLO]gnp.exe"), so it
            // gets the same scalar-safety fence as every other displayed
            // free-text field, present-but-hostile drops the whole frame.
            let validatedName: String?
            if let name {
                guard let ok = Self.validatedFreeText(name) else { return nil }
                validatedName = ok
            } else {
                validatedName = nil
            }
            return .handoffNotify(HandoffNotify(path: validatedPath, name: validatedName, mediaKind: mediaKind, bytes: bytes))

        case "permission-request":
            guard let tool,
                let validatedTool = Self.validatedFreeText(tool),
                let target,
                let validatedTarget = Self.validatedFreeText(target),
                let expiresAt
            else { return nil }
            // A present-but-hostile `summary` drops the whole frame rather
            // than silently blanking it: substituting "no summary" for a
            // rejected one is itself a soft coercion, the exact thing the
            // drop-never-coerce rule forbids.
            let validatedSummary: String?
            if let summary {
                guard let ok = Self.validatedFreeText(summary) else {
                    return nil
                }
                validatedSummary = ok
            } else {
                validatedSummary = nil
            }
            return .permissionRequest(
                PermissionRequest(tool: validatedTool, target: validatedTarget, summary: validatedSummary, expiresAt: expiresAt)
            )

        case "permission-decision":
            guard let inReplyTo,
                let decision,
                let scope,
                let target,
                let validatedTarget = Self.validatedFreeText(target)
            else { return nil }
            return .permissionDecision(
                PermissionDecision(inReplyTo: inReplyTo, decision: decision, scope: scope, target: validatedTarget)
            )

        case "permission-resolved":
            guard let inReplyTo, let reason else { return nil }
            return .permissionResolved(PermissionResolved(inReplyTo: inReplyTo, reason: reason))

        default:
            return nil
        }
    }

    /// Rejects NUL/bidi/zero-width scalars (`UnicodeHygiene`'s path-safety
    /// fence — the spec calls out this exact guard for every free-text
    /// field, not just paths). No length cap: the field's own per-type
    /// frame byte cap (already enforced before this ever runs) is the
    /// real bound; see `tool`/`summary`/`target`/`name` call sites below.
    fileprivate static func validatedFreeText(_ raw: String) -> String? {
        UnicodeHygiene.containsUnsafePathScalars(raw) ? nil : raw
    }

    /// `title`/`path` additionally enforce a numeric length cap that cites
    /// a real pre-existing repo convention (see `FieldLimit`'s doc comment)
    /// rather than a number invented for this task.
    fileprivate static func validatedFreeText(_ raw: String, maxLength: Int) -> String? {
        guard raw.utf8.count <= maxLength, let validated = validatedFreeText(raw) else {
            return nil
        }
        return validated
    }

    /// `path` gets the free-text checks above plus the "plausible absolute
    /// path" fence from `AmxBackend.parseCwdOutput`: an absolute prefix,
    /// since a relative path is meaningless without the remote's cwd.
    fileprivate static func validatedRemotePath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), let validated = validatedFreeText(raw, maxLength: BridgeMessage.FieldLimit.path) else {
            return nil
        }
        return validated
    }
}
