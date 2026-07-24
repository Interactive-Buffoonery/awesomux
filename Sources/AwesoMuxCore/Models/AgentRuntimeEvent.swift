import AwesoMuxBridgeProtocol
import Foundation
import UnicodeHygiene
import os

public struct AgentRuntimeEvent: Equatable, Sendable {
    public static let protocolName = "awesomux-agent-v1"
    public static let supportedVersion = 1
    public static let maximumLineByteCount = 4 * 1024

    private static let decoder = JSONDecoder()
    private static let logger = Logger(subsystem: "awesomux.agent", category: "runtime-event")

    public var version: Int
    public var source: AgentRuntimeSource
    public var kind: AgentKind?
    public var executionState: AgentExecutionState?
    public var attentionReason: AttentionReason?
    public var state: AgentState?
    public var phase: AgentRuntimePhase?
    public var eventID: String?
    public var providerSessionID: String?
    /// The target title for a `.rename` phase event. Empty string requests a
    /// reset to the live terminal title.
    public var title: String?
    /// The absolute local Markdown path for an `.openDocument` phase event.
    public var documentPath: String?
    /// An absolute local Markdown file the agent just wrote/edited, forwarded so
    /// it can be surfaced (recorded into the pane's recent links) even when its
    /// console output was hard-wrapped and un-clickable (issue #175). Only
    /// meaningful on a Claude Code `.toolEnd` event; `parse` nils it out on any
    /// other source/phase so the declared scope is enforced at the trust
    /// boundary, not just by the helper that happens to emit it.
    public var touchedPath: String?
    public var timestamp: Date?

    /// Whether this event itself asserts the fully receptive `.waiting`
    /// execution state — a narrower check than `AgentRuntimeEventReducer`'s
    /// own `eventExecutionState` derivation, which also gates on
    /// `!state.lifecycle.isEnded`; this property omits that gate and reads
    /// only `executionState ?? state?.executionState`. Callers that need the
    /// reducer's exact effective value must additionally check ground-truth
    /// pane state, the way the trust-stamping call site below already does
    /// (`newState == .waiting`) — that second check is what keeps the
    /// omitted `isEnded` gate from mattering there specifically; don't reuse
    /// this property elsewhere assuming full parity with the reducer.
    /// Distinguishes "this event told us waiting" from "the pane merely
    /// already reads waiting from an earlier event" (a title-only `.rename`,
    /// a tool-lifecycle event, a same-state repeat with neither field set).
    /// Load-bearing for `AgentPromptGate` trust-stamping (INT-569 follow-up):
    /// only an event that ASSERTS waiting may mint new prompt-verified trust
    /// — an accepted event that merely left a stale `.waiting` untouched must
    /// never re-stamp trust for whatever process happens to be foreground now.
    public var assertsWaitingExecutionState: Bool {
        (executionState ?? state?.executionState) == .waiting
    }

    public init(
        version: Int = AgentRuntimeEvent.supportedVersion,
        source: AgentRuntimeSource,
        kind: AgentKind? = nil,
        executionState: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        state: AgentState? = nil,
        phase: AgentRuntimePhase? = nil,
        eventID: String? = nil,
        providerSessionID: String? = nil,
        title: String? = nil,
        documentPath: String? = nil,
        touchedPath: String? = nil,
        timestamp: Date? = nil
    ) {
        self.version = version
        self.source = source
        self.kind = kind
        self.executionState = executionState
        self.attentionReason = attentionReason
        self.state = state
        self.phase = phase
        self.eventID = eventID
        self.providerSessionID = providerSessionID
        self.title = title
        self.documentPath = documentPath
        self.touchedPath = touchedPath
        self.timestamp = timestamp
    }

    public static func parse(line: String) -> AgentRuntimeEvent? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return parse(data: data)
    }

    public static func parse(data: Data) -> AgentRuntimeEvent? {
        guard data.count <= maximumLineByteCount else {
            return nil
        }

        do {
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.v == supportedVersion else {
                return nil
            }
            let documentPath: String?
            if payload.phase == .openDocument {
                guard let rawPath = payload.documentPath,
                    let validatedPath = validatedDocumentPath(rawPath)
                else {
                    return nil
                }
                documentPath = validatedPath
            } else {
                documentPath = nil
            }

            // Scope enforcement at the trust boundary: `touchedPath` only means
            // "a Claude Code tool just wrote this Markdown file" (issue #175).
            // The bundled helper only sets it on a claude-code PostToolUse
            // (`.toolEnd`) event, but the event file is same-UID-writable, so a
            // forged event on another source/phase must not smuggle a path into
            // the recent-links surface. An invalid path is dropped without
            // dropping the whole event, since a real `.toolEnd` still carries a
            // load-bearing execution transition.
            let touchedPath: String?
            if payload.source == .claudeCode,
                payload.phase == .toolEnd,
                let rawPath = payload.touchedPath?.value
            {
                touchedPath = validatedTouchedPath(rawPath)
            } else {
                touchedPath = nil
            }

            return AgentRuntimeEvent(
                version: payload.v,
                source: payload.source,
                kind: payload.kind,
                executionState: payload.execution,
                attentionReason: payload.attentionReason,
                state: payload.state,
                phase: payload.phase,
                eventID: payload.eventID,
                providerSessionID: payload.providerSessionID,
                title: payload.title,
                documentPath: documentPath,
                touchedPath: touchedPath,
                timestamp: payload.timestamp?.date
            )
        } catch {
            #if DEBUG
                logger.debug("agent runtime event parse failed: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    public static func validatedDocumentPath(_ path: String) -> String? {
        guard !path.isEmpty,
            !path.contains("\0"),
            (path as NSString).isAbsolutePath
        else {
            return nil
        }

        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard DocumentURLValidator.allowedExtensions.contains(fileExtension) else {
            return nil
        }

        return path
    }

    /// A touched path must clear the same absolute-Markdown gate as an
    /// open-document path AND be free of bidi/RTL-override scalars. The extra
    /// scalar check (which `validatedDocumentPath` leaves to open time) matters
    /// here because a recorded-but-unopenable link is exactly the "click looks
    /// dead" symptom issue #175 is about — so a path that the open path would
    /// later reject never gets recorded in the first place.
    public static func validatedTouchedPath(_ path: String) -> String? {
        guard let validated = validatedDocumentPath(path),
            !UnicodeHygiene.containsUnsafePathScalars(validated),
            // A literal `#` is legal in a POSIX filename but the recent-link open
            // path (`MarkdownLinkIntercept.documentPathPayload`) parses a bare
            // path as link syntax and strips everything from the first `#` as a
            // fragment, so `/tmp/#175.md` reduces to `/tmp/` and fails to open.
            // Recording it would be a dead palette entry — the exact "click looks
            // dead" symptom this feature avoids — so drop it. Only `#` is
            // stripped that way: `?` is preserved by `URL(fileURLWithPath:)` and
            // opens correctly, so it is intentionally allowed. Ceiling: revisit if
            // the open path grows raw-path handling that round-trips `#`.
            !validated.contains("#")
        else {
            return nil
        }
        return validated
    }

    private struct Payload: Decodable {
        var v: Int
        var source: AgentRuntimeSource
        var kind: AgentKind?
        var execution: AgentExecutionState?
        var attentionReason: AttentionReason?
        var state: AgentState?
        var phase: AgentRuntimePhase?
        var eventID: String?
        var providerSessionID: String?
        var title: String?
        var documentPath: String?
        // `touchedPath` rides on a `.toolEnd` event that carries a load-bearing
        // execution transition, so — unlike `documentPath`, which only appears
        // on document-only `open-document` events — a wrong-typed value must
        // strip just the field, never throw and drop the whole event. Lenient
        // decoding gives it that: a present-but-non-string value (array/number)
        // decodes to a `LenientString` whose `value` is nil rather than throwing.
        var touchedPath: LenientString?
        var timestamp: RuntimeTimestamp?
    }

    /// Decodes a JSON string field without letting a wrong-typed value sink the
    /// enclosing object's decode. Held as an optional so absent/null keys use
    /// the synthesized `decodeIfPresent` (→ nil); a present non-string decodes
    /// to `value == nil` via the `try?` here.
    private struct LenientString: Decodable {
        var value: String?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private enum RuntimeTimestamp: Decodable {
        case date(Date)

        // ISO8601DateFormatter's date(from:) is documented thread-safe after
        // configuration, so sharing a single instance across actors is fine.
        nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        var date: Date {
            switch self {
            case .date(let date):
                date
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let seconds = try? container.decode(Double.self) {
                self = .date(Date(timeIntervalSince1970: seconds))
                return
            }

            let rawValue = try container.decode(String.self)
            if let date = Self.date(from: rawValue) {
                self = .date(date)
                return
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown agent runtime timestamp: \(rawValue)"
            )
        }

        private static func date(from rawValue: String) -> Date? {
            fractionalFormatter.date(from: rawValue)
                ?? plainFormatter.date(from: rawValue)
        }
    }
}
