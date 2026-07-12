import Foundation
import Testing
@testable import awesoMux

@Suite("AppRuntimeProfile")
struct AppRuntimeProfileTests {
    private let applicationSupportURL = URL(
        fileURLWithPath: "/Users/example/Library/Application Support",
        isDirectory: true
    )
    private let temporaryDirectory = "/var/folders/example/T/"

    @Test("production bundle id maps to production paths")
    func productionBundleID() {
        let profile = AppRuntimeProfile.resolve(
            bundleIdentifier: AppRuntimeProfile.productionBundleIdentifier
        )

        #expect(profile == .production)
        #expect(profile.supportDirectoryURL(applicationSupportDirectory: applicationSupportURL).path
            == "/Users/example/Library/Application Support/awesoMux")
        #expect(profile.configDirectoryName == "awesomux")
        #expect(profile.amxSocketDirectoryPath(temporaryDirectory: temporaryDirectory)
            == "/var/folders/example/T/amx")
    }

    @Test("development bundle id maps to isolated dev paths")
    func developmentBundleID() {
        let profile = AppRuntimeProfile.resolve(
            bundleIdentifier: AppRuntimeProfile.developmentBundleIdentifier
        )

        #expect(profile == .development(worktreeID: nil))
        #expect(profile.supportDirectoryURL(applicationSupportDirectory: applicationSupportURL).path
            == "/Users/example/Library/Application Support/awesoMux-dev")
        #expect(profile.configDirectoryName == "awesomux-dev")
        #expect(profile.amxSocketDirectoryPath(temporaryDirectory: temporaryDirectory)
            == "/var/folders/example/T/amx-dev")
    }

    @Test("linked-worktree bundle id maps to its own isolated paths")
    func linkedWorktreeBundleID() {
        let worktreeID = "0123456789ab"
        let profile = AppRuntimeProfile.resolve(
            bundleIdentifier: "\(AppRuntimeProfile.developmentBundleIdentifier).\(worktreeID)"
        )

        #expect(profile == .development(worktreeID: worktreeID))
        #expect(profile.supportDirectoryURL(applicationSupportDirectory: applicationSupportURL).path
            == "/Users/example/Library/Application Support/awesoMux-dev-0123456789ab")
        #expect(profile.configDirectoryName == "awesomux-dev-0123456789ab")
        #expect(profile.amxSocketDirectoryName == "051u7i0")
        #expect(profile.amxSocketDirectoryPath(temporaryDirectory: temporaryDirectory)
            == "/var/folders/example/T/051u7i0")
        #expect(profile.environmentValue == "development:0123456789ab")
    }

    @Test("worktree socket namespace stays within the daemon path budget")
    func worktreeSocketPathBudget() {
        let profile = AppRuntimeProfile.development(worktreeID: "ffffffffffff")
        let longestTemporaryDirectory = "/var/folders/83/7b7fy7fn5jv0f655ltwhv2bw0000gp/T/"
        let socketDirectory = profile.amxSocketDirectoryPath(
            temporaryDirectory: longestTemporaryDirectory
        )
        let maximumSessionIDLength = 46
        let nulTerminatorLength = 1

        #expect(profile.amxSocketDirectoryName.utf8.count == "amx-dev".utf8.count)
        #expect(socketDirectory.utf8.count + 1 + maximumSessionIDLength + nulTerminatorLength <= 104)
    }

    @Test("nil and unknown bundle ids fail isolated, into the dev profile")
    func fallbackBundleIDs() {
        // A nil/unknown identity (`swift run`, bare .build binary, test
        // runner) is never the installed app — it must not land on the
        // installed app's session snapshot, config, or amx socket dir.
        #expect(AppRuntimeProfile.resolve(bundleIdentifier: nil) == .development(worktreeID: nil))
        #expect(AppRuntimeProfile.resolve(bundleIdentifier: "com.example.other") == .development(worktreeID: nil))
        #expect(AppRuntimeProfile.resolve(
            bundleIdentifier: "\(AppRuntimeProfile.developmentBundleIdentifier).too-short"
        ) == .development(worktreeID: nil))
        #expect(AppRuntimeProfile.resolve(
            bundleIdentifier: "\(AppRuntimeProfile.developmentBundleIdentifier).0123456789AZ"
        ) == .development(worktreeID: nil))
    }
}
