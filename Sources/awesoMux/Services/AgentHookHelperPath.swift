import Foundation

/// The absolute path to the bundled `awesoMuxAgentHook` helper, resolved from the
/// running app bundle, used to bake plugin hook configs at render time.
///
/// Plugin hooks run in the agent's process, which does not inherit the app
/// bundle's `Contents/MacOS` on `PATH`, and exec-form hooks do not expand shell
/// env vars — so a bare command name cannot find the helper and Claude's
/// `${CLAUDE_PLUGIN_ROOT}` resolves to the ephemeral plugin cache, not the app
/// bundle. The rendered hook therefore carries this absolute path. See
/// ADR-0012 decision 3.
struct AgentHookHelperPath: Equatable, Sendable {
    var path: String

    /// A helper that lives inside a `dist/` development build. The baked path
    /// keeps working only as long as that build folder survives, so the settings
    /// surface warns the user that a release build is needed for a durable
    /// install. (ADR-0012 decision 3.)
    var isDevelopmentBundle: Bool

    /// Resolves the helper beside the app's main executable. Returns `nil` when
    /// the bundle has no executable URL (e.g. a unit-test host), leaving callers
    /// to fall back to the `${AWESOMUX_AGENT_HOOK}` env override.
    static func resolve(
        bundledHookURL: URL? = AgentRuntimeEnvironment.bundledHookURL()
    ) -> AgentHookHelperPath? {
        guard let bundledHookURL else {
            return nil
        }
        let path = bundledHookURL.path
        return AgentHookHelperPath(
            path: path,
            isDevelopmentBundle: pathIsInsideDevelopmentBuild(path)
        )
    }

    /// A helper under a `dist/` directory is a local build artifact rather than an
    /// installed release. Matching on a `dist` path component (not a substring)
    /// avoids flagging an unrelated directory whose name merely contains "dist".
    static func pathIsInsideDevelopmentBuild(_ path: String) -> Bool {
        URL(fileURLWithPath: path)
            .pathComponents
            .contains("dist")
    }
}
