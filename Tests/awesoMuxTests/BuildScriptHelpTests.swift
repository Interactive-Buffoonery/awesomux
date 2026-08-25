import AwesoMuxTestSupport
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
            // Absence is meaningful because the three assertions above read the
            // same buffer: every one of these scripts answers `--help` with a
            // single `usage` heredoc then `exit 0`, before any validation and
            // before the only backgrounded commands in the tree — so a
            // truncated capture would fail those presence checks first rather
            // than silently satisfying this one.
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
        #expect(result.output.contains("AWESOMUX_ZMX_ZIG"))
        #expect(result.output.contains("AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS"))
        #expect(result.output.contains("AWESOMUX_PERF_SAMPLE_PORTS"))
    }

    @Test("app build help works without Sparkle release inputs")
    func appBuildHelpWorksWithoutSparkleReleaseInputs() throws {
        let result = try Self.run(script: "script/build_and_run.sh", arguments: ["--help"])

        #expect(result.exitStatus == 0)
        #expect(result.output.contains("Usage:"))
        #expect(!result.output.contains("SPARKLE_PUBLIC_ED_KEY is required"))
    }

    @Test("enabled build rejects an empty Sparkle public key before building")
    func enabledBuildRejectsEmptySparklePublicKeyBeforeBuilding() throws {
        let result = try Self.run(
            script: "script/build_and_run.sh",
            arguments: ["--stage-release"],
            environment: ["AWESOMUX_SPARKLE_ENABLED": "1"]
        )

        #expect(result.exitStatus == 2)
        #expect(result.output.contains("SPARKLE_PUBLIC_ED_KEY is required when AWESOMUX_SPARKLE_ENABLED=1"))
        #expect(!result.output.contains("ensure_ghostty_artifacts.sh"))
    }

    @Test("enabled Sparkle configuration rejects development and install modes before building", arguments: [[], ["--install"]])
    func enabledSparkleConfigurationRejectsNonReleaseModesBeforeBuilding(arguments: [String]) throws {
        // Mutation caught: removing the release-mode guard lets these invocations
        // reach their build/install prerequisites instead of rejecting the flag.
        let result = try Self.runCopiedBuildScript(
            arguments: arguments,
            environment: [
                "AWESOMUX_SPARKLE_ENABLED": "1",
                "SPARKLE_PUBLIC_ED_KEY": "test-public-ed-key",
            ]
        )

        #expect(result.exitStatus == 2)
        #expect(result.output.contains("AWESOMUX_SPARKLE_ENABLED=1 is only supported by --stage-release or stage-release"))
        #expect(!result.output.contains("ensure_ghostty_artifacts.sh"))
    }

    @Test("default Sparkle updater policy omits feed credentials")
    func defaultSparkleUpdaterPolicyOmitsFeedCredentials() throws {
        // Mutation caught: unconditionally writing the updater configuration,
        // or treating an unset enable flag as enabled, leaks release credentials.
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-sparkle-default-policy")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let infoPlist = temporaryDirectory.url.appendingPathComponent("Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleName</key><string>awesoMux</string></dict></plist>
        """.write(to: infoPlist, atomically: true, encoding: .utf8)

        let policyBlock = try Self.sparkleUpdaterPolicyBlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "set -euo pipefail\nINFO_PLIST=\"\(infoPlist.path)\"\nunset AWESOMUX_SPARKLE_ENABLED SPARKLE_PUBLIC_ED_KEY\n\(policyBlock)",
        ]
        let captured = try captureOutput(of: process)
        #expect(process.terminationStatus == 0, "output: \(captured.stdout)\(captured.stderr)")

        let data = try Data(contentsOf: infoPlist)
        let values = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "configured Info.plist is not a dictionary"
        )

        #expect(values["SUFeedURL"] == nil)
        #expect(values["SUPublicEDKey"] == nil)
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

    @Test("release build rejects missing version before staging")
    func releaseBuildRejectsMissingVersionBeforeStaging() throws {
        let result = try Self.run(script: "script/build_release.sh", arguments: ["--unsigned"])

        #expect(result.exitStatus == 2)
        #expect(result.output.contains("--version X.Y.Z is required"))
        #expect(!result.output.contains("build_and_run.sh"))
    }

    @Test("release build rejects invalid version and build number before staging")
    func releaseBuildRejectsInvalidVersionAndBuildNumberBeforeStaging() throws {
        let invalidVersion = try Self.run(
            script: "script/build_release.sh",
            arguments: ["--unsigned", "--version", "0.12.0-rc1"]
        )
        let invalidBuild = try Self.run(
            script: "script/build_release.sh",
            arguments: ["--unsigned", "--version", "0.12.0", "--build-number", "abc"]
        )

        #expect(invalidVersion.exitStatus == 2)
        #expect(invalidVersion.output.contains("--version must be X.Y.Z"))
        #expect(!invalidVersion.output.contains("build_and_run.sh"))
        #expect(invalidBuild.exitStatus == 2)
        #expect(invalidBuild.output.contains("--build-number must be a positive integer"))
        #expect(!invalidBuild.output.contains("build_and_run.sh"))
    }

    @Test("updater-enabled release rejects a missing public key before staging")
    func updaterEnabledReleaseRejectsMissingPublicKeyBeforeStaging() throws {
        let result = try Self.run(
            script: "script/build_release.sh",
            arguments: ["--unsigned", "--enable-sparkle", "--version", "0.12.0", "--build-number", "722"]
        )

        #expect(result.exitStatus == 2)
        #expect(result.output.contains("SPARKLE_PUBLIC_ED_KEY is required with --enable-sparkle"))
        #expect(!result.output.contains("build_and_run.sh"))
    }

    @Test("release build configures staging and signs Sparkle inside out")
    func releaseBuildConfiguresAndSignsSparkleInsideOut() throws {
        let script = try Self.contents(of: "script/build_release.sh")

        let staging = try #require(script.range(of: "\"$ROOT_DIR/script/build_and_run.sh\" --stage-release"))
        let sparkleEnabledExport = try #require(script.range(of: "export AWESOMUX_SPARKLE_ENABLED=1"))
        let sparkleKeyExport = try #require(script.range(of: "export SPARKLE_PUBLIC_ED_KEY"))
        #expect(sparkleEnabledExport.lowerBound < staging.lowerBound)
        #expect(sparkleKeyExport.lowerBound < staging.lowerBound)

        let autoupdate = try #require(script.range(of: "codesign \"${SIGN_ARGS[@]}\" \"$SPARKLE_AUTOUPDATE\""))
        let updater = try #require(script.range(of: "codesign \"${SIGN_ARGS[@]}\" \"$SPARKLE_UPDATER\""))
        let framework = try #require(script.range(of: "codesign \"${SIGN_ARGS[@]}\" \"$SPARKLE_FRAMEWORK\""))
        let app = try #require(script.range(of: "codesign \"${SIGN_ARGS[@]}\" \"$APP_BUNDLE\""))
        #expect(autoupdate.lowerBound < updater.lowerBound)
        #expect(updater.lowerBound < framework.lowerBound)
        #expect(framework.lowerBound < app.lowerBound)

        #expect(script.contains("$SPARKLE_FRAMEWORK/Versions/B/XPCServices"))
        #expect(script.contains("$SPARKLE_AUTOUPDATE"))
        #expect(script.contains("$SPARKLE_UPDATER"))
        #expect(script.contains("SIGNATURE_TARGETS"))
        #expect(script.contains("ENTITLEMENT_TARGETS"))

        let signingLines = script.split(separator: "\n").filter {
            $0.contains("codesign") && $0.contains("SIGN_ARGS")
        }
        #expect(!signingLines.isEmpty)
        #expect(signingLines.allSatisfy { !$0.contains("--deep") })
    }

    @Test("release build rejects a dirty worktree before staging")
    func releaseBuildRejectsDirtyWorktreeBeforeStaging() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-release-git-test-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let fakeGit = directory.appendingPathComponent("git")
        try "#!/bin/sh\nprintf ' M tracked-file\\n'\n".write(to: fakeGit, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        let path = "\(directory.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try Self.run(
            script: "script/build_release.sh",
            arguments: ["--unsigned", "--version", "0.12.0", "--build-number", "722"],
            environment: ["PATH": path]
        )

        #expect(result.exitStatus == 1)
        #expect(result.output.contains("worktree is not clean"))
        #expect(!result.output.contains("build_and_run.sh"))
    }

    private static let scripts = [
        "script/build_and_run.sh",
        "script/build_ghostty_xcframework.sh",
        "script/ensure_ghostty_artifacts.sh",
    ]

    private static func runHelp(script: String, argument: String) throws -> ShellResult {
        try run(
            script: script,
            arguments: [argument],
            environment: ["AWESOMUX_GHOSTTY_OPTIMIZE": "invalid-test-value"]
        )
    }

    private static func run(
        script: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> ShellResult {
        let root = try packageRootURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent(script).path] + arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, testValue in testValue }

        let captured = try captureOutput(of: process)
        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout + captured.stderr
        )
    }

    private static func runCopiedBuildScript(
        arguments: [String],
        environment: [String: String]
    ) throws -> ShellResult {
        let root = try packageRootURL()
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-sparkle-mode-gate")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let scriptDirectory = temporaryDirectory.url.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("script/build_and_run.sh"),
            to: scriptDirectory.appendingPathComponent("build_and_run.sh")
        )
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("script/runtime-profile.sh"),
            to: scriptDirectory.appendingPathComponent("runtime-profile.sh")
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptDirectory.appendingPathComponent("build_and_run.sh").path] + arguments
        process.currentDirectoryURL = temporaryDirectory.url
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, testValue in testValue }

        let captured = try captureOutput(of: process)
        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout + captured.stderr
        )
    }

    private static func contents(of relativePath: String) throws -> String {
        let url = try packageRootURL().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func sparkleUpdaterPolicyBlock() throws -> String {
        let script = try contents(of: "script/build_and_run.sh")
        let start = try #require(
            script.range(of: "\nif [[ \"${AWESOMUX_SPARKLE_ENABLED:-}\" == \"1\" ]]; then\n  /usr/libexec/PlistBuddy")?.lowerBound,
            "Sparkle updater policy block not found"
        )
        let end = try #require(
            script.range(of: "\n# Ad-hoc codesign", range: start..<script.endIndex)?.lowerBound,
            "end of Sparkle updater policy block not found"
        )
        return String(script[start..<end])
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
