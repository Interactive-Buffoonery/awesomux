import Foundation
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
    public var timestamp: Date?

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
        var timestamp: RuntimeTimestamp?
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

public enum AgentRuntimeSource: String, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case pi
    case grok
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AgentRuntimeSource(rawValue: rawValue) ?? .unknown
    }

    /// Maps a runtime event source to the agent kind it implies, used as a
    /// fallback when the event omits an explicit `kind`. Returns nil for
    /// sources without a corresponding AgentKind so `.shell` stays `.shell`.
    public var inferredAgentKind: AgentKind? {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .grok:
            .grok
        case .unknown:
            nil
        }
    }

    var hasTrustworthySessionRestartBoundary: Bool {
        switch self {
        case .claudeCode, .pi:
            true
        case .codex, .openCode, .grok, .unknown:
            false
        }
    }
}

public enum AgentRuntimePhase: String, Codable, Sendable {
    case sessionStart
    case promptSubmit
    case toolStart
    case toolEnd
    case notification
    case stop
    case sessionEnd
    case rename
    case openDocument = "open-document"
}
