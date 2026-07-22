import Testing
@testable import awesoMux

@Suite("ClaudePluginList parsing")
struct ClaudePluginListParsingTests {
    @Test("parses the current CLI's flat id field")
    func parsesFlatIDField() throws {
        let json = """
            [
              {
                "id": "awesomux-claude-status@awesomux-claude",
                "version": "0.1.0",
                "scope": "user",
                "enabled": true,
                "installPath": "/Users/x/.claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0",
                "installedAt": "2026-07-17T14:48:47.467Z",
                "lastUpdated": "2026-07-17T14:48:47.467Z"
              }
            ]
            """
        let entries = try ClaudePluginList.parse(json)
        #expect(entries.count == 1)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(entries[0].matches(ref))
        #expect(entries[0].enabled)
    }

    @Test("still parses the legacy split name/marketplace fields")
    func parsesLegacySplitFields() throws {
        let json = """
            [{"name": "awesomux-claude-status", "marketplace": "awesomux-claude", "enabled": true, "errors": []}]
            """
        let entries = try ClaudePluginList.parse(json)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(entries[0].matches(ref))
    }

    @Test("does not match a differently-named id")
    func rejectsMismatchedID() throws {
        let json = """
            [{"id": "some-other-plugin@some-other-marketplace", "enabled": true}]
            """
        let entries = try ClaudePluginList.parse(json)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(!entries[0].matches(ref))
    }

    @Test(
        "rejects malformed id shapes rather than guessing",
        arguments: ["", "@market", "name@", "name", "a@b@c"]
    )
    func rejectsMalformedIDShapes(id: String) throws {
        let json = "[{\"id\": \"\(id)\", \"enabled\": true}]"
        let entries = try ClaudePluginList.parse(json)
        #expect(entries[0].name == nil, "id \"\(id)\" should not parse a usable name")
    }
}
