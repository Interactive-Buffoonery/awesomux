import AwesoMuxTestSupport
import Foundation
import Testing

@Suite
struct AgentIntegrationTemplateTests {
    @Test
    func openCodeTemplateUsesProviderOnlyHelperInvocation() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        )

        #expect(template.contains("process.env.AWESOMUX_AGENT_HOOK"))
        #expect(template.contains("\"awesoMuxAgentHook\""))
        #expect(template.contains("${hook} --provider opencode"))
        #expect(template.contains("session_id: sessionID"))
        // Child sessions (task subagents) are tracked separately so neither
        // session.created nor chat.message can promote them into the root set:
        // a promoted child's session.idle used to emit a false parent turn-end
        // (Stop → awesoMux "waiting") mid-turn.
        #expect(template.contains("childSessionIDs"))
        #expect(template.contains("if (info.parentID)"))
        // Fail closed: an unknown/missing session id must drop the event, not
        // emit it — OpenCode payload shapes have varied across versions.
        #expect(template.contains("if (!rootSessionIDs.has(sessionID))"))
        #expect(template.contains("!childSessionIDs.has(sessionID)"))
        #expect(template.contains("chat.message\": async ({ sessionID })"))
        #expect(template.contains("session.created"))
        #expect(template.contains("session.idle"))
        #expect(template.contains("session.error"))
        #expect(template.contains("chat.message"))
        #expect(template.contains("permission.ask"))
        #expect(template.contains("tool.execute.before"))
        #expect(template.contains("tool.execute.after"))
        #expect(!template.contains("AWESOMUX_AGENT_ENABLED_SOURCES"))
        #expect(!template.contains("AWESOMUX_SOURCE"))
    }

    @Test
    func openCodeTemplateRoutesOnlyRootLifecycleEvents() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        )
        let fixtureURL = try Self.packageRootURL()
            .appendingPathComponent("Tests/Fixtures/opencode-session-routing-events.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtures = try JSONDecoder().decode([OpenCodeRoutingFixture].self, from: fixtureData)

        #expect(
            fixtures.map(\.name) == [
                "root lifecycle",
                "child lifecycle",
                "unknown lifecycle",
                "missing ID lifecycle",
                "out-of-order child lifecycle",
                "child lifecycle after tracking pressure",
                "root permission bus events",
            ])

        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-opencode-routing")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let harnessURL = temporaryDirectory.url.appendingPathComponent("routing-harness.mjs")
        try Data((template + Self.openCodeRoutingHarness).utf8).write(to: harnessURL)

        let node = try #require(
            Self.executableOnPath("node"),
            "Node is required to evaluate the bundled OpenCode status template"
        )
        let process = Process()
        process.executableURL = node
        process.arguments = [harnessURL.path, fixtureURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AWESOMUX_AGENT_EVENT_PROTOCOL": "awesomux-agent-v1",
            "AWESOMUX_AGENT_EVENT_FILE": "/tmp/awesomux-routing-test-events.jsonl",
            "AWESOMUX_AGENT_HOOK": "awesoMuxAgentHook",
        ]) { _, new in new }
        let output = try captureOutput(of: process)
        try #require(process.terminationStatus == 0, "Node routing harness failed: \(output.stderr)")

        let outputs = try JSONDecoder().decode([OpenCodeRoutingOutput].self, from: Data(output.stdout.utf8))
        #expect(outputs.map(\.name) == fixtures.map(\.name))
        for fixture in fixtures {
            let output = try #require(outputs.first { $0.name == fixture.name })
            #expect(output.emitted == fixture.expected)
        }
    }

    @Test
    func openCodeTemplateSeparatesPermissionBusEventsFromPluginHookKeys() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        )

        // `permission.asked` / `permission.replied` are event-bus types, not plugin
        // hook keys, and `session.status` is a state snapshot rather than a
        // turn-start signal. Neither should ever reappear as hook keys.
        #expect(!template.contains("\"permission.asked\": async"))
        #expect(!template.contains("\"permission.replied\": async"))
        #expect(template.contains("\"permission.asked\": \"PermissionRequest\""))
        #expect(template.contains("\"permission.replied\": \"PermissionReplied\""))
        #expect(!template.contains("session.status"))
    }

    @Test
    func openCodeTemplateDoesNotForwardSensitiveProviderPayloads() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        )

        try Self.expectNoSensitiveProviderPayloadForwarding(in: template)
    }

    @Test
    func piTemplateUsesProviderOnlyHelperInvocation() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/pi/awesomux-pi-status.ts.template"
        )

        #expect(template.contains("process.env.AWESOMUX_AGENT_HOOK"))
        #expect(template.contains("\"awesoMuxAgentHook\""))
        #expect(template.contains("spawn(hook, [\"--provider\", \"pi\"]"))
        #expect(template.contains("session_id: sessionID"))
        #expect(template.contains("ctx.sessionManager.getSessionId()"))
        #expect(template.contains("session_start"))
        #expect(template.contains("before_agent_start"))
        #expect(template.contains("tool_execution_start"))
        #expect(template.contains("tool_execution_end"))
        #expect(template.contains("agent_end"))
        #expect(template.contains("session_shutdown"))
        #expect(!template.contains("AWESOMUX_AGENT_ENABLED_SOURCES"))
        #expect(!template.contains("AWESOMUX_SOURCE"))
    }

    @Test
    func piTemplateDoesNotForwardSensitiveProviderPayloads() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/pi/awesomux-pi-status.ts.template"
        )

        try Self.expectNoSensitiveProviderPayloadForwarding(in: template)
        try Self.expectNoPiContextForwarding(in: template)
    }

    @Test
    func grokHooksUseProviderOnlyHelperInvocation() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/grok/plugins/awesomux-grok-status/hooks/hooks.json"
        )
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any]
        )
        let hooks = try #require(decoded["hooks"] as? [String: [[String: Any]]])
        let expectedEvents = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "SubagentStart",
            "SubagentStop",
            "PermissionDenied",
            "Notification",
            "Stop",
            "SessionEnd",
            "StopFailure"
        ]
        let expectedCommand = "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}; \"$AWESOMUX_AGENT_HOOK\" --provider grok"

        #expect(Set(hooks.keys) == Set(expectedEvents))
        #expect(!hooks.keys.contains { $0.contains("_") })
        for event in expectedEvents {
            let hookBlocks = try #require(hooks[event])
            let block = try #require(hookBlocks.first)
            let commands = try #require(block["hooks"] as? [[String: Any]])
            let command = try #require(commands.first)

            #expect(hookBlocks.count == 1)
            #expect(commands.count == 1)
            #expect(command["type"] as? String == "command")
            #expect(command["command"] as? String == expectedCommand)
            #expect(command["timeout"] as? Int == 10)
        }
        #expect(!template.contains("AWESOMUX_AGENT_ENABLED_SOURCES"))
        #expect(!template.contains("toolInput"))
        #expect(!template.contains("toolResult"))
    }

    @Test
    func expectedAgentIntegrationTemplatesExist() throws {
        let packageRoot = try Self.packageRootURL()
        let root = packageRoot.appendingPathComponent("Resources/AgentIntegrations")
        let templates = [
            "open_code/awesomux-opencode-status.js.template",
            "pi/awesomux-pi-status.ts.template",
            "grok/plugins/awesomux-grok-status/hooks/hooks.json"
        ]

        for template in templates {
            let url = root.appendingPathComponent(template)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private static func expectNoSensitiveProviderPayloadForwarding(in template: String) throws {
        let stringifyCalls = template.components(separatedBy: "JSON.stringify(").count - 1
        #expect(stringifyCalls == 1)
        #expect(template.contains("hook_event_name: hookEventName"))

        let forbiddenSnippets = [
            "JSON.stringify(event",
            "JSON.stringify(input",
            "JSON.stringify(output",
            "event.prompt",
            "input.prompt",
            "output.args",
            "event.args",
            "event.input",
            "event.messages",
            "event.payload",
            "event.result",
            "event.systemPrompt",
            "input.cwd",
            "event.filePath",
            "input.filePath",
            "output.filePath"
        ]

        for snippet in forbiddenSnippets {
            #expect(!template.contains(snippet))
        }
    }

    private static func expectNoPiContextForwarding(in template: String) throws {
        let forbiddenSnippets = [
            "ctx.cwd",
            "ctx.model",
            "getContextUsage"
        ]

        for snippet in forbiddenSnippets {
            #expect(!template.contains(snippet))
        }
    }

    @Test
    func buildScriptStagesAgentIntegrationResources() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("Resources/AgentIntegrations"))
        #expect(script.contains("$APP_RESOURCES/AgentIntegrations"))
        #expect(script.contains("cp -R \"$APP_AGENT_INTEGRATIONS/.\""))
    }

    private static func contents(of relativePath: String) throws -> String {
        let root = try packageRootURL()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func packageRootURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = root.appendingPathComponent("Package.swift")
        try #require(
            FileManager.default.fileExists(atPath: manifest.path),
            "Package.swift not found at \(manifest.path); the test file likely moved depth"
        )
        return root
    }

    private static func executableOnPath(_ name: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static let openCodeRoutingHarness = #"""

        import { readFileSync } from "node:fs"

        const fixtures = JSON.parse(readFileSync(process.argv[2], "utf8"))
        const outputs = []
        const lifecycleEventTypes = new Set(["session.created", "session.idle", "session.error"])
        const permissionEventTypes = new Set(["permission.asked", "permission.replied"])

        for (const fixture of fixtures) {
            if (!Array.isArray(fixture.steps) || fixture.steps.length === 0) {
                throw new Error(`routing fixture ${fixture.name} has no steps`)
            }
            const emitted = []
            const capture = (_strings, ...values) => ({
                quiet: async () => {
                    const response = values.find((value) => value instanceof Response)
                    if (!response) {
                        throw new Error("awesoMux hook invocation did not include a Response payload")
                    }
                    emitted.push(JSON.parse(await response.text()))
                },
            })
            const handlers = await AwesoMuxOpenCodeStatus({ $: capture })

            for (const step of fixture.steps) {
                if (step.repeatChildSessionCreated !== undefined) {
                    if (Object.keys(step).length !== 1) {
                        throw new Error(`routing fixture ${fixture.name} mixes repeat and event fields`)
                    }
                    if (!Number.isInteger(step.repeatChildSessionCreated) || step.repeatChildSessionCreated < 1) {
                        throw new Error(`routing fixture ${fixture.name} has an invalid child repeat`)
                    }
                    for (let index = 0; index < step.repeatChildSessionCreated; index += 1) {
                        await handlers.event({
                            event: {
                                type: "session.created",
                                properties: {
                                    info: { id: `filler-child-${index}`, parentID: "root-session" },
                                },
                            },
                        })
                    }
                    continue
                }
                if (step.handler === "event") {
                    const allowedStepKeys = new Set(["handler", "input", "allowMissingSessionID"])
                    if (Object.keys(step).some((key) => !allowedStepKeys.has(key))) {
                        throw new Error(`routing fixture ${fixture.name} has unknown event fields`)
                    }
                    if (!lifecycleEventTypes.has(step.input?.type)
                        && !permissionEventTypes.has(step.input?.type)
                        || typeof step.input.properties !== "object"
                        || step.input.properties === null
                        || Array.isArray(step.input.properties)) {
                        throw new Error(`routing fixture ${fixture.name} has an invalid lifecycle event`)
                    }
                    const sessionID = step.input.properties.info?.id
                        ?? step.input.properties.sessionID
                    if (step.allowMissingSessionID !== true && typeof sessionID !== "string") {
                        throw new Error(`routing fixture ${fixture.name} has a lifecycle event without an ID`)
                    }
                    if (step.allowMissingSessionID === true
                        && (step.input.type === "session.created" || sessionID !== undefined)) {
                        throw new Error(`routing fixture ${fixture.name} expected a missing lifecycle ID`)
                    }
                    if (permissionEventTypes.has(step.input.type)
                        && typeof step.input.properties.sessionID !== "string") {
                        throw new Error(`routing fixture ${fixture.name} has a permission event without sessionID`)
                    }
                    await handlers.event({ event: step.input })
                    continue
                }
                if (Object.keys(step).some((key) => key !== "handler" && key !== "input")) {
                    throw new Error(`routing fixture ${fixture.name} has unknown handler fields`)
                }
                if (step.handler !== "chat.message" || typeof step.input?.sessionID !== "string") {
                    throw new Error(`routing fixture ${fixture.name} has an invalid handler`)
                }
                await handlers[step.handler](step.input)
            }

            outputs.push({ name: fixture.name, emitted })
        }

        process.stdout.write(JSON.stringify(outputs))
        """#

    private struct OpenCodeRoutingFixture: Decodable {
        let name: String
        let expected: [OpenCodeHookEmission]
    }

    private struct OpenCodeRoutingOutput: Decodable {
        let name: String
        let emitted: [OpenCodeHookEmission]
    }

    private struct OpenCodeHookEmission: Decodable, Equatable {
        let hookEventName: String
        let sessionID: String?

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: OpenCodeHookEmissionKey.self)
            let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
            let unexpectedKeys = Set(raw.allKeys.map(\.stringValue)).subtracting(allowedKeys)
            guard unexpectedKeys.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unexpected OpenCode hook payload keys: \(unexpectedKeys.sorted())"
                    ))
            }

            let values = try decoder.container(keyedBy: CodingKeys.self)
            hookEventName = try values.decode(String.self, forKey: .hookEventName)
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case hookEventName = "hook_event_name"
            case sessionID = "session_id"
        }
    }

    private struct OpenCodeHookEmissionKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
