import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@Suite("OpenCode transcript exporter")
struct OpenCodeTranscriptExporterTests {
    @Test("export invokes the configured executable with the exact session id")
    func invokesConfiguredExecutable() async throws {
        let invocation = Invocation()
        let result = await OpenCodeTranscriptExporter.export(
            sessionID: "ses_01JABC",
            setup: AgentIntegrationSetup(binaryPath: "/usr/bin/true"),
            run: { executable, arguments in
                await invocation.record(executable: executable, arguments: arguments)
                return Data(#"{"messages":[]}"#.utf8)
            }
        )

        _ = try result.get()
        #expect(await invocation.executable?.path == "/usr/bin/true")
        #expect(await invocation.arguments == ["export", "ses_01JABC"])
    }

    @Test("a missing configured executable fails before spawning")
    func missingExecutableFailsClosed() async {
        let result = await OpenCodeTranscriptExporter.export(
            sessionID: "ses_01JABC",
            setup: AgentIntegrationSetup(binaryPath: "/missing/opencode")
        )

        #expect(result == .failure(.executableNotFound))
    }
}

private actor Invocation {
    private(set) var executable: URL?
    private(set) var arguments: [String] = []

    func record(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}
