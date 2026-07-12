public enum AgentRuntimeEnvironmentKey {
    public static let eventProtocol = "AWESOMUX_AGENT_EVENT_PROTOCOL"
    public static let sessionID = "AWESOMUX_SESSION_ID"
    public static let paneID = "AWESOMUX_PANE_ID"
    public static let eventFile = "AWESOMUX_AGENT_EVENT_FILE"
    public static let agentHook = "AWESOMUX_AGENT_HOOK"
    public static let enabledSources = "AWESOMUX_AGENT_ENABLED_SOURCES"
    public static let amx = "AWESOMUX_AMX"
    public static let profile = "AWESOMUX_PROFILE"

    public static let paneScopedKeys = [
        eventProtocol,
        sessionID,
        paneID,
        eventFile,
        agentHook,
        enabledSources,
        amx,
        profile
    ]

    // `amx` is deliberately absent from `healthCheckRequiredKeys`: local-shell
    // fallback panes (missing amx binary, bridge disabled) must still pass the
    // runtime health check.

    public static let healthCheckRequiredKeys = [
        eventProtocol,
        sessionID,
        paneID,
        eventFile
    ]
}
