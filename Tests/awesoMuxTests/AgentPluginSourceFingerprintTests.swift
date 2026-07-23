import CryptoKit
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

    @Test("versioned digest differs from a legacy pre-version install record")
    func versionedDigestDiffersFromLegacyRecord() throws {
        let resources = Self.packageResourcesURL
        AgentPluginSourceFingerprint.resetDigestCacheForTests()
        // The real migration boundary: an install recorded by an app that
        // computed the digest WITHOUT the render-format prefix must read as stale
        // against the current default digest, so the fix re-delivers to existing
        // installs (issue #164). Reproduce that legacy transcript exactly.
        let legacy = try Self.legacyUnversionedDigest(provider: .grok, resources: resources)
        let current = try #require(
            AgentPluginSourceFingerprint.digest(
                provider: .grok,
                resourcesDirectoryURL: resources
            )
        )
        #expect(current != legacy)
    }

    /// The pre-change digest algorithm: file transcript only, no render-format
    /// prefix. Kept in the test so a regression that drops the prefix (and would
    /// silently strand existing installs) fails here.
    private static func legacyUnversionedDigest(
        provider: AgentPluginProvider,
        resources: URL
    ) throws -> String {
        let root = resources.appending(path: provider.bundledTreeRelativePath, directoryHint: .isDirectory)
        var hasher = SHA256()
        for relativePath in AgentPluginSourceFingerprint.contentRelativePaths(for: provider).sorted() {
            let data = try Data(contentsOf: root.appending(path: relativePath))
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
