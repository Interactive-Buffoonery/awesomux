import Foundation
import Testing
@testable import awesoMux

@Suite
struct SubprocessSafetyTests {
    @Test("output beyond 512 KiB throws instead of returning a partial result")
    func oversizedCommandOutputIsRejected() async throws {
        let runner = ProcessCommandRunner(timeout: .seconds(10))
        for redirect in ["", " >&2"] {
            do {
                _ = try await runner.run(
                    executable: "/bin/sh",
                    args: ["-c", "{ printf '{\"valid\":true}'; /usr/bin/head -c 524289 /dev/zero; }\(redirect)"],
                    env: [:],
                    cwd: nil
                )
                Issue.record("oversized output returned a partial result")
            } catch let error as CommandRunnerError {
                #expect(error == .outputTruncated("/bin/sh", 512 * 1024))
            }
        }
    }

    @Test("shell quoting preserves quotes, backslashes, and newlines literally")
    func shellSingleQuotedPreservesPaths() async throws {
        let renderer = AgentPluginTemplateRenderer()
        let runner = ProcessCommandRunner(timeout: .seconds(10))
        for path in [
            "/Applications/Terminal Tools/awesoMux.app",
            "/tmp/eD!'s \"Tools\"\\folder/awesoMuxAgentHook",
            "/tmp/line\nbreak/awesoMuxAgentHook",
            "/tmp/$(printf injected); `printf injected`/awesoMuxAgentHook",
        ] {
            let result = try await runner.run(
                executable: "/bin/sh",
                args: ["-c", "printf '%s' \(renderer.shellSingleQuoted(path))"],
                env: [:],
                cwd: nil
            )
            #expect(result.exitCode == 0)
            #expect(result.stdout == path)
            #expect(result.stderr.isEmpty)
        }
    }
}
