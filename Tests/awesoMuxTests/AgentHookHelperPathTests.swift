import Foundation
import Testing
@testable import awesoMux

@Suite("Agent hook helper path")
struct AgentHookHelperPathTests {
    @Test("resolves the helper path beside a release bundle executable")
    func resolvesReleaseBundlePath() {
        let hookURL = URL(fileURLWithPath: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook")
        let resolved = AgentHookHelperPath.resolve(bundledHookURL: hookURL)
        #expect(resolved?.path == hookURL.path)
        #expect(resolved?.isDevelopmentBundle == false)
    }

    @Test("flags a dist development build so the user is warned the path is fragile")
    func flagsDevelopmentBuild() {
        let hookURL = URL(fileURLWithPath: "/Users/example/dev/awesomux/dist/awesoMux.app/Contents/MacOS/awesoMuxAgentHook")
        let resolved = AgentHookHelperPath.resolve(bundledHookURL: hookURL)
        #expect(resolved?.isDevelopmentBundle == true)
    }

    @Test("a directory merely containing 'dist' in its name is not a development build")
    func substringDistIsNotFlagged() {
        let hookURL = URL(fileURLWithPath: "/Applications/redistributable/awesoMux.app/Contents/MacOS/awesoMuxAgentHook")
        #expect(AgentHookHelperPath.pathIsInsideDevelopmentBuild(hookURL.path) == false)
    }

    @Test("a nil bundle URL resolves to nil so callers fall back to the env override")
    func nilBundleResolvesNil() {
        #expect(AgentHookHelperPath.resolve(bundledHookURL: nil) == nil)
    }
}
