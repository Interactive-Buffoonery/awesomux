import AwesoMuxTestSupport
import Foundation
import Testing

@Suite("Runtime profile shell contract")
struct RuntimeProfileScriptTests {
    @Test("worktree ids are stable and path-specific")
    func worktreeIDsAreStableAndPathSpecific() throws {
        let first = try run("awesomux_worktree_id /tmp/awesomux-one")
        let repeated = try run("awesomux_worktree_id /tmp/awesomux-one")
        let second = try run("awesomux_worktree_id /tmp/awesomux-two")

        #expect(first.status == 0)
        #expect(first.output.range(of: #"^[0-9a-f]{12}$"#, options: .regularExpression) != nil)
        #expect(first.output == repeated.output)
        #expect(first.output != second.output)
    }

    @Test("worktree profile resolves bundle support config and socket names")
    func worktreeProfilePaths() throws {
        let result = try run("awesomux_resolve_profile development:0123456789ab; awesomux_print_profile")

        #expect(result.status == 0)
        let expectedOutput = [
            "profile=development:0123456789ab",
            "bundle=com.interactivebuffoonery.awesomux.dev.0123456789ab",
            "display=awesoMux (dev 0123456)",
            "support=awesoMux-dev-0123456789ab",
            "config=awesomux-dev-0123456789ab",
            "socket=051u7i0"
        ].joined(separator: "\n")
        #expect(result.output == expectedOutput)
    }

    @Test("primary and linked checkouts select legacy and isolated development profiles")
    func checkoutProfiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-profile-checkouts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let primary = directory.appending(path: "primary", directoryHint: .isDirectory)
        let linked = directory.appending(path: "linked", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = try run(
            """
            set -e
            git init -q -b main "$2"
            git -C "$2" config user.name test
            git -C "$2" config user.email test@example.com
            touch "$2/seed"
            git -C "$2" add seed
            git -C "$2" commit -q -m seed
            git -C "$2" worktree add -q -b linked "$3"
            awesomux_checkout_profile "$2"
            awesomux_checkout_profile "$3"
            """,
            arguments: [primary.path, linked.path]
        )

        let profiles = result.output.split(separator: "\n").map(String.init)
        #expect(result.status == 0)
        #expect(profiles.first == "development")
        #expect(profiles.last?.range(
            of: #"^development:[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil)
    }

    @Test("production and legacy development profiles keep their paths")
    func stableProfilePaths() throws {
        let production = try run("awesomux_resolve_profile production; awesomux_print_profile")
        let development = try run("awesomux_resolve_profile development; awesomux_print_profile")

        #expect(production.output.contains("bundle=com.interactivebuffoonery.awesomux\n"))
        #expect(production.output.contains("support=awesoMux\n"))
        #expect(production.output.hasSuffix("socket=amx"))
        #expect(development.output.contains("bundle=com.interactivebuffoonery.awesomux.dev\n"))
        #expect(development.output.contains("support=awesoMux-dev\n"))
        #expect(development.output.hasSuffix("socket=amx-dev"))
    }

    @Test("malformed worktree profiles fail closed")
    func malformedProfileFails() throws {
        let result = try run("awesomux_resolve_profile development:too-short")

        #expect(result.status == 2)
        #expect(result.error.contains("invalid awesoMux runtime profile"))
    }

    @Test("reaper accepts exact worktree profiles in either argument order")
    func reaperSelectsWorktreeProfile() throws {
        let first = try runReaper(["--profile", "development:0123456789ab", "list"])
        let second = try runReaper(["list", "--profile", "development:0123456789ab"])

        #expect(first.status == 0)
        #expect(first.output.contains("profile: development:0123456789ab"))
        #expect(first.output.contains("/051u7i0"))
        #expect(first.output.contains("--profile development:0123456789ab orphans"))
        #expect(second.output == first.output)
    }

    @Test("reaper accepts legacy flags in either order")
    func reaperSelectsLegacyDevelopmentProfile() throws {
        let first = try runReaper(["--dev", "list"])
        let second = try runReaper(["list", "--dev"])
        let production = try runReaper(["list", "--prod"])

        #expect(first.status == 0)
        #expect(first.output.contains("profile: development"))
        #expect(first.output.contains("/amx-dev"))
        #expect(first.output.contains("--dev orphans"))
        #expect(second.output == first.output)
        #expect(production.output.contains("profile: production"))
    }

    @Test("reaper inherits a profile only inside an awesoMux pane")
    func reaperUsesInjectedPaneProfile() throws {
        let profile = "development:0123456789ab"
        let insidePane = try runReaper([], inheritedProfile: profile, insidePane: true)
        let outsidePane = try runReaper([], inheritedProfile: profile, insidePane: false)

        #expect(insidePane.output.contains("profile: \(profile)"))
        #expect(insidePane.output.contains("/051u7i0"))
        #expect(outsidePane.output.contains("profile: production"))
        #expect(outsidePane.output.contains("/amx"))
    }

    @Test("reaper defaults to production and rejects malformed profile ids")
    func reaperDefaultsAndValidation() throws {
        let production = try runReaper(["list"])
        let malformed = try runReaper(["--profile", "development:bad", "all"])

        #expect(production.status == 0)
        #expect(production.output.contains("profile: production"))
        #expect(production.output.contains("--prod orphans"))
        #expect(malformed.status == 2)
        #expect(malformed.error.contains("invalid awesoMux runtime profile"))
    }

    private func run(_ command: String, arguments: [String] = []) throws -> ShellResult {
        let scriptURL = try Self.packageRootURL()
            .appending(path: "script/runtime-profile.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\"; \(command)", "runtime-profile-test", scriptURL.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try process.waitUntilExitEventually()

        return ShellResult(
            status: process.terminationStatus,
            output: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .newlines) ?? "",
            error: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func runReaper(
        _ arguments: [String],
        inheritedProfile: String? = nil,
        insidePane: Bool = false
    ) throws -> ShellResult {
        let root = try Self.packageRootURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-reaper-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeAmx = temporaryDirectory.appending(path: "amx")
        try Data("#!/usr/bin/env bash\nexit 0\n".utf8).write(to: fakeAmx)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeAmx.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appending(path: "script/amx-reap.sh").path] + arguments
        var environment = [
            "AWESOMUX_AMX": fakeAmx.path,
            "HOME": temporaryDirectory.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]
        environment["AWESOMUX_PROFILE"] = inheritedProfile
        if insidePane {
            environment["AWESOMUX_PANE_ID"] = "test-pane"
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try process.waitUntilExitEventually()
        return ShellResult(
            status: process.terminationStatus,
            output: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            error: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func packageRootURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try #require(FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path))
        return root
    }

    private struct ShellResult {
        var status: Int32
        var output: String
        var error: String
    }
}
