import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

struct AgentRuntimeConsent: Equatable, Sendable {
    var enabledFileDropSources: Set<AgentRuntimeSource>

    init(enabledFileDropSources: Set<AgentRuntimeSource>) {
        self.enabledFileDropSources = enabledFileDropSources
    }

    static func enabledFileDropSources(from integrations: AgentIntegrationsConfig) -> Set<AgentRuntimeSource> {
        // This allowlist gates file-drop providers only; Claude/Codex/Grok hooks
        // are provider-managed and trusted once they reach the pane-scoped sink.
        var sources: Set<AgentRuntimeSource> = []
        if integrations.openCode.enabled {
            sources.insert(.openCode)
        }
        if integrations.pi.enabled {
            sources.insert(.pi)
        }
        return sources
    }

    static func environmentValue(for fileDropSources: Set<AgentRuntimeSource>) -> String {
        fileDropSources
            .filter { $0 == .openCode || $0 == .pi }
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    func allows(_ event: AgentRuntimeEvent) -> Bool {
        switch event.source {
        case .openCode:
            return enabledFileDropSources.contains(.openCode)
        case .pi:
            return enabledFileDropSources.contains(.pi)
        case .claudeCode, .codex, .grok:
            return true
        case .unknown:
            break
        }

        switch event.kind {
        case .openCode?:
            return enabledFileDropSources.contains(.openCode)
        case .pi?:
            return enabledFileDropSources.contains(.pi)
        case .claudeCode?, .codex?, .grok?:
            return true
        case .shell?, nil:
            return true
        }
    }
}

struct AgentRuntimeEnvironment {
    static let hookExecutableName = "awesoMuxAgentHook"

    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
    let eventFileURL: URL
    let enabledFileDropSources: Set<AgentRuntimeSource>
    let profileValue: String
    /// Absolute path to the bundled hook helper. Panes do not inherit the app
    /// bundle's `Contents/MacOS` on `PATH`, so plugin templates resolve the
    /// helper through `AWESOMUX_AGENT_HOOK` instead of a bare command name.
    let agentHookURL: URL?
    /// Absolute path to the bundled `amx` backend, same not-on-PATH rationale
    /// as `agentHookURL`. Unlike the hook path (whose default has no
    /// executable check), the amx default is gated on `isExecutableFile`:
    /// nil (missing/non-executable binary) omits the var, so `AWESOMUX_AMX`
    /// never advertises a dead path. See docs/amx-automation.md.
    let amxURL: URL?

    init(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        eventFileURL: URL,
        enabledFileDropSources: Set<AgentRuntimeSource> = [],
        profileValue: String = AppRuntimeProfile.current.environmentValue,
        agentHookURL: URL? = AgentRuntimeEnvironment.bundledHookURL(),
        amxURL: URL? = AmxBackend.bundledExecutableURL()
    ) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.eventFileURL = eventFileURL
        self.enabledFileDropSources = enabledFileDropSources
        self.profileValue = profileValue
        self.agentHookURL = agentHookURL
        self.amxURL = amxURL
    }

    var environment: [String: String] {
        var values = [
            AgentRuntimeEnvironmentKey.eventProtocol: AgentRuntimeEvent.protocolName,
            AgentRuntimeEnvironmentKey.sessionID: sessionID.uuidString,
            AgentRuntimeEnvironmentKey.paneID: paneID.uuidString,
            AgentRuntimeEnvironmentKey.eventFile: eventFileURL.path,
            AgentRuntimeEnvironmentKey.enabledSources: AgentRuntimeConsent.environmentValue(for: enabledFileDropSources),
            AgentRuntimeEnvironmentKey.profile: profileValue
        ]
        if let agentHookURL {
            values[AgentRuntimeEnvironmentKey.agentHook] = agentHookURL.path
        }
        if let amxURL {
            values[AgentRuntimeEnvironmentKey.amx] = amxURL.path
        }
        return values
    }

    /// The helper ships beside the app's main executable in `Contents/MacOS`.
    static func bundledHookURL() -> URL? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(hookExecutableName)
    }
}
