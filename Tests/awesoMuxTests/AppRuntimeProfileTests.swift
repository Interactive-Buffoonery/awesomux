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

    /// The regression guard for #296, and the only one here that exercises the
    /// live detection rather than the pure resolver: before the `.test` case,
    /// this process resolved to `.development(nil)` and every status file the
    /// suite minted landed in the running dev build's own socket directory,
    /// where the next run then counted them as its own.
    @Test("the running test process is isolated from the dev build")
    func currentProfileIsTestIsolated() {
        let processID = ProcessInfo.processInfo.processIdentifier
        let devBuild = AppRuntimeProfile.development(worktreeID: nil)

        #expect(AppRuntimeProfile.current == .test(processID: processID))
        #expect(AppRuntimeProfile.current.amxSocketDirectoryName != devBuild.amxSocketDirectoryName)
        #expect(!AmxBackend.sessionSocketDirectory().hasSuffix("/amx-dev"))
        #expect(!AmxBackend.sessionSocketDirectory().hasSuffix("/amx"))
    }

    /// An Xcode test host hands the suite the app's own Info.plist. Reading it
    /// would put the tests back on the shipping app's socket dir — the failure
    /// mode this case exists to prevent, one profile over.
    @Test(
        "a test runner outranks any bundle id it inherits",
        arguments: [
            AppRuntimeProfile.productionBundleIdentifier,
            AppRuntimeProfile.developmentBundleIdentifier,
            "\(AppRuntimeProfile.developmentBundleIdentifier).0123456789ab",
            nil,
        ] as [String?]
    )
    func testRunnerOutranksBundleID(bundleIdentifier: String?) {
        #expect(
            AppRuntimeProfile.resolve(bundleIdentifier: bundleIdentifier, isTestRunner: true)
                == .test(processID: ProcessInfo.processInfo.processIdentifier)
        )
    }

    @Test("two test processes never share a socket directory")
    func testProfilePathsAreProcessScoped() {
        let first = AppRuntimeProfile.test(processID: 4242)
        let second = AppRuntimeProfile.test(processID: 4243)

        #expect(first.amxSocketDirectoryName != second.amxSocketDirectoryName)
        #expect(first.supportDirectoryName == "awesoMux-test-4242")
        #expect(first.configDirectoryName == "awesomux-test-4242")
        #expect(first.environmentValue == "test:4242")
        #expect(first.sshControlDirectoryName == "ssh-test")
    }

    /// Same budget as `worktreeSocketPathBudget`, swept across the whole `Int32`
    /// range rather than the pids macOS actually issues. `0` and the negatives
    /// are not paranoia about the kernel: `testSocketNamespace` only avoids a
    /// `String(repeating:count:)` trap because it takes `suffix` BEFORE
    /// subtracting, and nothing but this sweep would notice a refactor that
    /// reorders those two steps.
    @Test(
        "test socket namespace stays within the daemon path budget",
        arguments: [1, 99999, 0, -1, .min, .max] as [Int32]
    )
    func testSocketPathBudget(processID: Int32) {
        let longestTemporaryDirectory = "/var/folders/83/7b7fy7fn5jv0f655ltwhv2bw0000gp/T/"
        let maximumSessionIDLength = 46
        let nulTerminatorLength = 1
        let profile = AppRuntimeProfile.test(processID: processID)
        let socketDirectory = profile.amxSocketDirectoryPath(
            temporaryDirectory: longestTemporaryDirectory
        )

        #expect(profile.amxSocketDirectoryName.utf8.count == 6)
        #expect(socketDirectory.utf8.count + 1 + maximumSessionIDLength + nulTerminatorLength <= 104)
    }

    /// The regression guard for a collision three independent reviews found:
    /// `amx` is not a reserved prefix, because base-36 spells `a`, `m` and `x`
    /// like any other digit. Worktree `5640ea939abc` and pid 12345 both used to
    /// encode to `amx09ix`, which would have put a test run inside a live
    /// worktree dev build's socket directory — #296 again, one profile over.
    ///
    /// The fix is structural, so the guard is too: worktree namespaces are
    /// always exactly seven characters and test namespaces always exactly six,
    /// and two strings of different lengths cannot be equal. Asserting the
    /// widths is therefore strictly stronger than spot-checking known
    /// collisions, which would only ever prove the two inputs named above.
    @Test("a test namespace can never equal a worktree namespace")
    func testAndWorktreeNamespacesAreDisjointByWidth() {
        for worktreeID in ["5640ea939abc", "5640fff9f000", "0123456789ab", "000000000000", "ffffffffffff"] {
            #expect(AppRuntimeProfile.development(worktreeID: worktreeID).amxSocketDirectoryName.utf8.count == 7)
        }
        for processID: Int32 in [1, 12345, 99999, 0, -1, .min, .max] {
            #expect(AppRuntimeProfile.test(processID: processID).amxSocketDirectoryName.utf8.count == 6)
        }

        // The two inputs that actually collided before the fix.
        #expect(
            AppRuntimeProfile.test(processID: 12345).amxSocketDirectoryName
                != AppRuntimeProfile.development(worktreeID: "5640ea939abc").amxSocketDirectoryName
        )
        #expect(
            AppRuntimeProfile.test(processID: 99999).amxSocketDirectoryName
                != AppRuntimeProfile.development(worktreeID: "5640fff9f000").amxSocketDirectoryName
        )
    }

    @Test("nil and unknown bundle ids fail isolated, into the dev profile")
    func fallbackBundleIDs() {
        // A nil/unknown identity (`swift run`, a bare .build binary) is never
        // the installed app — it must not land on the installed app's session
        // snapshot, config, or amx socket dir. A test runner is excluded here
        // deliberately: it gets its own profile, above.
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
