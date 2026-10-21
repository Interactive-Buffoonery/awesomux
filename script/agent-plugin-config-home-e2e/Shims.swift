import Foundation

// Stand-ins for app-wide types the plugin runner names only in default
// arguments. The driver injects every directory and the helper explicitly, so
// none of these values is used on the exercised path.

enum SessionPersistence {
    static var supportDirectoryURL: URL { URL(fileURLWithPath: "/nonexistent-e2e-support") }
}

enum AgentRuntimeEnvironment {
    static let hookExecutableName = "awesoMuxAgentHook"
    static func bundledHookURL() -> URL? { nil }
}

enum AppRuntimeProfile {
    case development(worktreeID: String?)

    static let productionBundleIdentifier = "com.interactivebuffoonery.awesomux"
    var supportDirectoryURL: URL { URL(fileURLWithPath: "/nonexistent-e2e-legacy") }
}
