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

    @Test("a test runner outranks any bundle id it inherits")
    func testRunnerOutranksBundleID() {
        // An Xcode test host hands the suite the app's own Info.plist. Reading
        // it would put the tests back on the shipping app's socket dir — the
        // failure mode this case exists to prevent, one profile over.
        for bundleIdentifier in [
            AppRuntimeProfile.productionBundleIdentifier,
            AppRuntimeProfile.developmentBundleIdentifier,
            "\(AppRuntimeProfile.developmentBundleIdentifier).0123456789ab",
            nil,
        ] {
            #expect(
                AppRuntimeProfile.resolve(bundleIdentifier: bundleIdentifier, isTestRunner: true)
                    == .test(processID: ProcessInfo.processInfo.processIdentifier)
            )
        }
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

    /// Same budget as `worktreeSocketPathBudget`, swept across the pid range:
    /// `amx-dev`'s width is the ceiling, not a convention, so a namespace that
    /// grows with the pid has to be checked at the top of the range too.
    @Test("test socket namespace stays within the daemon path budget")
    func testSocketPathBudget() {
        let longestTemporaryDirectory = "/var/folders/83/7b7fy7fn5jv0f655ltwhv2bw0000gp/T/"
        let maximumSessionIDLength = 46
        let nulTerminatorLength = 1

        for processID: Int32 in [1, 99999, .max] {
            let profile = AppRuntimeProfile.test(processID: processID)
            let socketDirectory = profile.amxSocketDirectoryPath(
                temporaryDirectory: longestTemporaryDirectory
            )

            #expect(profile.amxSocketDirectoryName.utf8.count == "amx-dev".utf8.count)
            #expect(socketDirectory.utf8.count + 1 + maximumSessionIDLength + nulTerminatorLength <= 104)
        }
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
