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

    // MARK: - sessionExists

    /// Resume's probe answers existence from the lightweight `session list`
    /// metadata, not a full export — same executable policy, argv never a
    /// shell line.
    @Test("session existence comes from the session list metadata")
    func sessionExistsFromListMetadata() async {
        let invocation = Invocation()
        let answered = await OpenCodeTranscriptExporter.sessionExists(
            sessionID: "ses_01JABC",
            setup: AgentIntegrationSetup(binaryPath: "/usr/bin/true"),
            run: { executable, arguments in
                await invocation.record(executable: executable, arguments: arguments)
                return Data(
                    #"[{"id":"ses_older"},{"id":"ses_01JABC","title":"t","directory":"/x"}]"#.utf8
                )
            }
        )

        #expect(answered)
        #expect(await invocation.executable?.path == "/usr/bin/true")
        #expect(await invocation.arguments == ["session", "list", "--format", "json"])
    }

    @Test("a session absent from the list probes false")
    func sessionAbsentFromListProbesFalse() async {
        let answered = await OpenCodeTranscriptExporter.sessionExists(
            sessionID: "ses_01JABC",
            setup: .defaultValue,
            run: { _, _ in Data(#"[{"id":"ses_other"}]"#.utf8) }
        )

        #expect(!answered)
    }

    /// Every failure of the probe — no executable, a failed command, or
    /// output that is not the expected array — must read as "the log is
    /// missing", never as "resume is fine".
    @Test("session existence probing fails closed")
    func sessionExistsFailsClosed() async {
        struct ProbeError: Error {}
        let cases: [OpenCodeTranscriptExporter.Run] = [
            { _, _ in throw ProbeError() },
            { _, _ in Data() },
            { _, _ in Data(#"[{"name":"no id field"}]"#.utf8) },
        ]
        for run in cases {
            let answered = await OpenCodeTranscriptExporter.sessionExists(
                sessionID: "ses_01JABC",
                setup: AgentIntegrationSetup(binaryPath: "/usr/bin/true"),
                run: run
            )
            #expect(!answered)
        }

        #expect(
            await !OpenCodeTranscriptExporter.sessionExists(
                sessionID: "ses_01JABC",
                setup: AgentIntegrationSetup(binaryPath: "/missing/opencode")
            ))
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
