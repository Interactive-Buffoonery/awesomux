import AwesoMuxConfig
import Foundation

/// Value types for the ADR-0008 analytics pipeline. Grouped in one file
/// like `LocalDiagnosticEventModels` because they are small and only
/// meaningful together.
///
/// The privacy boundary starts with construction: capture sites submit
/// `AnalyticsEventInput` cases and property keys are a closed enum matching
/// the INT-768 allowlist. String-bearing values must pass validating factories,
/// and both the sanitizer and log store revalidate them before persistence.

let analyticsSchemaVersion = 1

/// The only entry point for capturing analytics. New events are new
/// cases with typed payloads; there is deliberately no generic
/// name-plus-dictionary form.
enum AnalyticsEventInput: Equatable, Sendable {
    case testPing
    case consentChanged(to: AnalyticsConfig.ConsentLevel)
    case appLaunched(AppLaunchSnapshot)
    case errorReported(AnalyticsErrorContext)
    case sessionCreated(
        shape: WorkspaceShapeSnapshot, sessionKind: AnalyticsSessionKind, agentKind: AnalyticsAgentKind?)
    case agentSessionStarted(kind: AnalyticsAgentKind, initialState: AnalyticsAgentState, usesReliableHooks: Bool)
    case agentStateChanged(
        kind: AnalyticsAgentKind, previous: AnalyticsAgentState, next: AnalyticsAgentState, source: AnalyticsAgentEventSource)
    case workspaceGroupChanged(action: WorkspaceGroupAction, shape: WorkspaceShapeSnapshot)
    case settingsChanged(area: AnalyticsSettingsArea)
    case diagnosticsOpened(section: AnalyticsDiagnosticsSection)
}

extension AnalyticsEventInput {
    /// The name this input would carry if sanitized — used so a dropped
    /// event still gets a named log line while its rejected payload never
    /// touches the log.
    var intendedName: AnalyticsEventName {
        switch self {
        case .testPing: .testPing
        case .consentChanged, .settingsChanged: .settingsChanged
        case .appLaunched: .appLaunched
        case .errorReported: .errorReported
        case .sessionCreated: .sessionCreated
        case .agentSessionStarted: .agentSessionStarted
        case .agentStateChanged: .agentStateChanged
        case .workspaceGroupChanged: .workspaceGroupChanged
        case .diagnosticsOpened: .diagnosticsOpened
        }
    }
}

enum AnalyticsEventName: String, Codable, Sendable {
    case testPing = "amx_test_ping"
    // Consent changes ride amx_settings_changed per INT-768: setting area
    // only, with the analytics consent level as the sole allowed raw value.
    case settingsChanged = "amx_settings_changed"
    case appLaunched = "amx_app_launched"
    case errorReported = "amx_error_reported"
    case sessionCreated = "amx_session_created"
    case agentSessionStarted = "amx_agent_session_started"
    case agentStateChanged = "amx_agent_state_changed"
    case workspaceGroupChanged = "amx_workspace_group_changed"
    case diagnosticsOpened = "amx_diagnostics_opened"
}

// MARK: - Typed payload vocabulary (closed enums, INT-768 slugs)

struct AppLaunchSnapshot: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let macOSMajor: Int
    let macOSMinor: Int
    let cpuArchitecture: String
}

struct AnalyticsErrorContext: Equatable, Sendable {
    let featureArea: AnalyticsFeatureArea
    let errorKind: AnalyticsErrorKind
    var remote: AnalyticsRemoteContext?
}

enum AnalyticsFeatureArea: String, CaseIterable, Equatable, Sendable {
    case runtime
    case configuration
    case restore
    case terminal
    case diagnostics
}

enum AnalyticsErrorKind: String, CaseIterable, Equatable, Sendable {
    case runtimeEventRejected = "runtime_event_rejected"
    case runtimeEventsDropped = "runtime_events_dropped"
    case runtimeEventFileUnavailable = "runtime_event_file_unavailable"
    case configurationRejected = "configuration_rejected"
    case configurationResetRejected = "configuration_reset_rejected"
    case restoreArchived = "restore_archived"
    case restoreSanitized = "restore_sanitized"
    case terminalFailed = "terminal_failed"
    case processSamplingFailed = "process_sampling_failed"
}

/// Derived remote context per INT-768's SSH error handling: never the
/// detector input, title, user, host, or IP — only presence enums and a
/// count bucket.
struct AnalyticsRemoteContext: Equatable, Sendable {
    enum Presence: String, CaseIterable, Equatable, Sendable {
        case remote
        case local
        case unknown
    }

    let presence: Presence
    let activePaneRemote: Bool?
    let remotePaneCount: Int
}

enum AnalyticsAgentKind: String, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode = "claude_code"
    case opencode
    case pi
    case grok
    case shell
}

/// Coarse locality of a created session, derived from its panes'
/// `ExecutionLocation`. Closed enum: raw values are the wire tokens.
enum AnalyticsSessionKind: String, CaseIterable, Equatable, Sendable {
    case local
    case remote
    case unknown
}

enum AnalyticsAgentState: String, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case waiting
    case thinking
    case output
    case needsAttention = "needs_attention"
    case done
    case error
}

enum AnalyticsAgentEventSource: String, CaseIterable, Equatable, Sendable {
    case hook
    case detected
}

enum WorkspaceGroupAction: String, CaseIterable, Equatable, Sendable {
    case added
    case removed
    // There is no `moved` case because the count-delta observer cannot see
    // moves. Add one only alongside a reliable move call site.
}

struct WorkspaceShapeSnapshot: Equatable, Sendable {
    let sessionCount: Int
    let paneCount: Int
    let groupCount: Int
}

enum AnalyticsSettingsArea: String, CaseIterable, Equatable, Sendable {
    case general
    case appearance
    case terminal
    case agents
    case agentIntegrations = "agent_integrations"
    case keyboard
    case notifications
    case workspaces
    case keys
    case advanced
    case analytics
}

enum AnalyticsDiagnosticsSection: String, CaseIterable, Equatable, Sendable {
    case overview
    case analytics
}

/// The INT-768 allowed-context-property allowlist. A key that is not a
/// case here cannot appear in any payload.
enum AnalyticsPropertyKey: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case appVersion = "app_version"
    case buildNumber = "build_number"
    case macosVersionMajor = "macos_version_major"
    case macosVersionMinor = "macos_version_minor"
    case cpuArch = "cpu_arch"
    case featureArea = "feature_area"
    case errorKind = "error_kind"
    case schemaVersion = "schema_version"
    case consentLevel = "consent_level"
    case sessionCountBucket = "session_count_bucket"
    case paneCountBucket = "pane_count_bucket"
    case workspaceGroupCountBucket = "workspace_group_count_bucket"
    case sessionKind = "session_kind"
    case remoteContext = "remote_context"
    case activePaneRemote = "active_pane_remote"
    case remotePaneCountBucket = "remote_pane_count_bucket"
    case settingsArea = "settings_area"
    case diagnosticsSection = "diagnostics_section"
    case action
    case agentKind = "agent_kind"
    case agentState = "agent_state"
    case previousAgentState = "previous_agent_state"
    case nextAgentState = "next_agent_state"
    case agentEventSource = "agent_event_source"
    case usesReliableHooks = "uses_reliable_hooks"
}

/// Low-cardinality count bucket per INT-768 (`0 | 1 | 2-3 | 4+`).
enum CountBucket: String, Codable, Equatable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToThree = "2-3"
    case fourPlus = "4+"

    init(count: Int) {
        switch count {
        case ..<1: self = .zero
        case 1: self = .one
        case 2...3: self = .twoToThree
        default: self = .fourPlus
        }
    }
}

/// Payload values. The pipeline constructs `version` and `token` through the
/// validating factories, which reject path-like, spaced, uppercase, and
/// oversized strings; the final log gate repeats that validation.
enum AnalyticsPropertyValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case bucket(CountBucket)
    case version(String)
    case token(String)

    /// Dotted numeric version, e.g. "1.4.0" or a build number "203".
    static func version(validating raw: String) -> AnalyticsPropertyValue? {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        guard raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return .version(raw)
    }

    /// Lowercase enum-like slug, e.g. "claude-code", "arm64", "remote".
    static func token(validating raw: String) -> AnalyticsPropertyValue? {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        let allowed = raw.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "_" || character == "-")
        }
        guard allowed else { return nil }
        return .token(raw)
    }

    var displayValue: String {
        switch self {
        case .bool(let value): String(value)
        case .integer(let value): String(value)
        case .bucket(let bucket): bucket.rawValue
        case .version(let value): value
        case .token(let value): value
        }
    }
}

extension AnalyticsPropertyValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case bool
        case integer
        case bucket
        case version
        case token
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "analytics property value must contain exactly one recognized tag"
                )
            )
        }
        switch key {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: key))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: key))
        case .bucket:
            self = .bucket(try container.decode(CountBucket.self, forKey: key))
        case .version:
            let raw = try container.decode(String.self, forKey: key)
            guard let value = AnalyticsPropertyValue.version(validating: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "analytics version fails allowlist validation"
                )
            }
            self = value
        case .token:
            let raw = try container.decode(String.self, forKey: key)
            guard let value = AnalyticsPropertyValue.token(validating: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "analytics token fails allowlist validation"
                )
            }
            self = value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .integer(let value): try container.encode(value, forKey: .integer)
        case .bucket(let bucket): try container.encode(bucket, forKey: .bucket)
        case .version(let value): try container.encode(value, forKey: .version)
        case .token(let value): try container.encode(value, forKey: .token)
        }
    }
}

/// An event that passed the sanitizer — the only shape eligible for the
/// local log or provider capture.
struct SanitizedAnalyticsEvent: Equatable, Sendable {
    let name: AnalyticsEventName
    let properties: [AnalyticsPropertyKey: AnalyticsPropertyValue]
}

/// `queued` is terminal for accepted events: the SDK exposes no
/// per-event delivery callback, so a confirmed "sent" cannot exist.
enum AnalyticsDeliveryStatus: String, Codable, Sendable {
    case queued
    case dropped
    case failed
}

enum AnalyticsDropReason: String, Codable, Sendable {
    case analyticsDisabled = "analytics_disabled"
    case consentInsufficient = "consent_insufficient"
    case invalidPropertyValue = "invalid_property_value"
    case deliveryUnavailable = "delivery_unavailable"
}

/// One line of the local analytics event log — exactly the fields the
/// diagnostics panel must display per INT-768.
struct AnalyticsLogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let name: AnalyticsEventName
    let consentLevel: AnalyticsConfig.ConsentLevel
    let properties: [AnalyticsPropertyKey: AnalyticsPropertyValue]
    let status: AnalyticsDeliveryStatus
    let dropReason: AnalyticsDropReason?
    let provider: String
    let schemaVersion: Int

    init(
        id: UUID,
        timestamp: Date,
        name: AnalyticsEventName,
        consentLevel: AnalyticsConfig.ConsentLevel,
        properties: [AnalyticsPropertyKey: AnalyticsPropertyValue],
        status: AnalyticsDeliveryStatus,
        dropReason: AnalyticsDropReason?,
        provider: String,
        schemaVersion: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.consentLevel = consentLevel
        self.properties = properties
        self.status = status
        self.dropReason = dropReason
        self.provider = provider
        self.schemaVersion = schemaVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let properties = try container.decode(
            [AnalyticsPropertyKey: AnalyticsPropertyValue].self,
            forKey: .properties
        )
        let consentLevel = try container.decode(AnalyticsConfig.ConsentLevel.self, forKey: .consentLevel)
        let provider = try container.decode(String.self, forKey: .provider)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard consentLevel != .off,
            provider == "posthog",
            schemaVersion == analyticsSchemaVersion,
            properties.allSatisfy({ AnalyticsSanitizer.isShapeValid($0.value, for: $0.key) })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .properties,
                in: container,
                debugDescription: "analytics log entry failed final privacy validation"
            )
        }

        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        name = try container.decode(AnalyticsEventName.self, forKey: .name)
        self.consentLevel = consentLevel
        self.properties = properties
        status = try container.decode(AnalyticsDeliveryStatus.self, forKey: .status)
        dropReason = try container.decodeIfPresent(AnalyticsDropReason.self, forKey: .dropReason)
        self.provider = provider
        self.schemaVersion = schemaVersion
    }
}
