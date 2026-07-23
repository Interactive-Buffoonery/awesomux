import Foundation
import Testing
@testable import awesoMux

@Suite("Agent plugin source fingerprint")
struct AgentPluginSourceFingerprintTests {
    @Test("digest is stable for a provider's bundled tree")
    func digestIsStable() {
        let resources = Self.packageResourcesURL
        let first = AgentPluginSourceFingerprint.digest(
            provider: .grok,
            resourcesDirectoryURL: resources
        )
        let second = AgentPluginSourceFingerprint.digest(
            provider: .grok,
            resourcesDirectoryURL: resources
        )
        #expect(first != nil)
        #expect(first == second)
        #expect(first?.count == 64)
    }

    @Test("digest covers Claude, Codex, and Grok trees")
    func digestCoversAllCLIProviders() {
        let resources = Self.packageResourcesURL
        for provider in AgentPluginProvider.allCases {
            let digest = AgentPluginSourceFingerprint.digest(
                provider: provider,
                resourcesDirectoryURL: resources
            )
            #expect(digest != nil, "expected digest for \(provider.rawValue)")
        }
    }

    @Test("digest changes when a content file body changes")
    func digestChangesWhenHooksChange() throws {
        try Self.withTemporaryResourcesCopy { resources in
            AgentPluginSourceFingerprint.resetDigestCacheForTests()
            let before = try #require(
                AgentPluginSourceFingerprint.digest(
                    provider: .claudeCode,
                    resourcesDirectoryURL: resources
                )
            )

            let hooksURL =
                resources
                .appending(path: "AgentIntegrations/claude_code/plugins/awesomux-claude-status/hooks/hooks.json")
            var hooks = try String(contentsOf: hooksURL, encoding: .utf8)
            hooks += "\n"
            try hooks.write(to: hooksURL, atomically: true, encoding: .utf8)

            AgentPluginSourceFingerprint.resetDigestCacheForTests()
            let after = try #require(
                AgentPluginSourceFingerprint.digest(
                    provider: .claudeCode,
                    resourcesDirectoryURL: resources
                )
            )
            #expect(before != after)
        }
    }

    @Test("digest changes when the render-format version changes")
    func digestChangesWithRenderFormatVersion() {
        let resources = Self.packageResourcesURL
        AgentPluginSourceFingerprint.resetDigestCacheForTests()
        // A record written under an older render format must read as stale after
        // the command shape changes, even though the bundled tree is untouched —
        // this is what re-delivers the fix to existing installs (issue #164).
        let v1 = AgentPluginSourceFingerprint.digest(
            provider: .grok,
            resourcesDirectoryURL: resources,
            renderFormatVersion: "1"
        )
        let v0 = AgentPluginSourceFingerprint.digest(
            provider: .grok,
            resourcesDirectoryURL: resources,
            renderFormatVersion: "0"
        )
        #expect(v1 != nil)
        #expect(v0 != nil)
        #expect(v1 != v0)
    }

    @Test("missing tree yields nil rather than a partial digest")
    func missingTreeYieldsNil() {
        let empty = FileManager.default.temporaryDirectory
            .appending(path: "empty-resources-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(
            AgentPluginSourceFingerprint.digest(
                provider: .codex,
                resourcesDirectoryURL: empty
            ) == nil
        )
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }

    private static func withTemporaryResourcesCopy(
        _ body: (URL) throws -> Void
    ) throws {
        let source = packageResourcesURL.appending(path: "AgentIntegrations")
        let root = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-fingerprint-\(UUID().uuidString)", directoryHint: .isDirectory)
        let dest = root.appending(path: "AgentIntegrations", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
        try body(root)
    }
}
