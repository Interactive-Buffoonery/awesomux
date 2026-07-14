import Foundation
import Testing

@Suite("Build script help")
struct BuildScriptHelpTests {
    @Test("help exits successfully before build validation", arguments: ["--help", "-h"])
    func helpExitsSuccessfullyBeforeBuildValidation(argument: String) throws {
        for script in Self.scripts {
            let result = try Self.runHelp(script: script, argument: argument)

            #expect(result.exitStatus == 0)
            #expect(result.output.contains("Usage:"))
            #expect(result.output.contains("AWESOMUX_GHOSTTY_OPTIMIZE"))
            #expect(result.output.contains("docs/ghostty-integration.md#build-the-xcframework"))
            #expect(!result.output.contains("is invalid"))
        }
    }

    @Test("Ghostty artifact help documents exact pin enforcement")
    func ghosttyArtifactHelpDocumentsExactPinEnforcement() throws {
        let result = try Self.runHelp(
            script: "script/ensure_ghostty_artifacts.sh",
            argument: "--help"
        )

        #expect(result.output.contains("AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH"))
    }

    @Test("Ghostty build help documents its Zig override")
    func ghosttyBuildHelpDocumentsZigOverride() throws {
        let result = try Self.runHelp(
            script: "script/build_ghostty_xcframework.sh",
            argument: "--help"
        )

        #expect(result.output.contains("AWESOMUX_ZIG"))
        #expect(result.output.contains("ReleaseFast (default)"))
    }

    @Test("app build help documents modes and mode-specific environment")
    func appBuildHelpDocumentsModesAndModeSpecificEnvironment() throws {
        let result = try Self.runHelp(script: "script/build_and_run.sh", argument: "--help")

        #expect(result.output.contains("--debug, debug"))
        #expect(result.output.contains("--install, install"))
        #expect(result.output.contains("AWESOMUX_INSTALL_DIR"))
        #expect(result.output.contains("AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS"))
        #expect(result.output.contains("AWESOMUX_PERF_SAMPLE_PORTS"))
    }

    @Test("live Codex smoke-test help documents its read-only inputs")
    func liveCodexSmokeTestHelpDocumentsInputs() throws {
        let result = try Self.runHelp(script: "script/test_live_codex_plugin.sh", argument: "--help")

        #expect(result.exitStatus == 0)
        #expect(result.output.contains("Usage:"))
        #expect(result.output.contains("read-only"))
        #expect(result.output.contains("CODEX_HOME"))
        #expect(result.output.contains("AWESOMUX_LIVE_CODEX_BINARY"))
    }

    @Test("Ghostty build sets a cold-build expectation")
    func ghosttyBuildSetsColdBuildExpectation() throws {
        let script = try Self.contents(of: "script/build_ghostty_xcframework.sh")

        #expect(script.contains("This build can take about 60-120 seconds"))
        #expect(script.contains("later app builds reuse the finished .build/ghostty artifacts"))
    }

    @Test("release build creates and staples a disk image")
    func releaseBuildCreatesAndStaplesDiskImage() throws {
        let script = try Self.contents(of: "script/build_release.sh")

        #expect(script.contains("hdiutil create"))
        #expect(script.contains("xcrun stapler staple \"$DMG_PATH\""))
        #expect(script.contains("hdiutil attach \"$DMG_PATH\" -readonly"))
        #expect(!script.contains("ZIP_PATH"))
    }

    private static let scripts = [
        "script/build_and_run.sh",
        "script/build_ghostty_xcframework.sh",
        "script/ensure_ghostty_artifacts.sh",
    ]

    private static func runHelp(script: String, argument: String) throws -> ShellResult {
        let root = try packageRootURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent(script).path, argument]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AWESOMUX_GHOSTTY_OPTIMIZE": "invalid-test-value",
        ]) { _, testValue in testValue }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            + stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return ShellResult(exitStatus: process.terminationStatus, output: output)
    }

    private static func contents(of relativePath: String) throws -> String {
        let url = try packageRootURL().appendingPathComponent(relativePath)
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

    private struct ShellResult {
        let exitStatus: Int32
        let output: String
    }
}
