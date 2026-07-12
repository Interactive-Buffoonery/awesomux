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
        #expect(template.contains("JSON.stringify({ hook_event_name: hookEventName })"))
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
    func openCodeTemplateAvoidsInvalidOpenCodeHookKeys() throws {
        let template = try Self.contents(
            of: "Resources/AgentIntegrations/open_code/awesomux-opencode-status.js.template"
        )

        // `permission.asked` is an event-bus type, not a plugin hook key, and
        // `session.status` is a state snapshot rather than a turn-start signal.
        // Neither should ever reappear in the template.
        #expect(!template.contains("permission.asked"))
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
        #expect(template.contains("JSON.stringify({ hook_event_name: hookEventName })"))
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
        #expect(template.contains("JSON.stringify({ hook_event_name: hookEventName })"))

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
}
