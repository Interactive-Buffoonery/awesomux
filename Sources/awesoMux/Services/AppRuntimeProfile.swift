import Foundation

enum AppRuntimeProfile: Equatable, Sendable {
    case production
    case development(worktreeID: String?)
    /// A test process. It carries no bundle identity of its own, so it used to
    /// fall through to `.development(nil)` — byte-identical to the profile a
    /// plain `./script/build_and_run.sh` build runs under. The suite therefore
    /// wrote status files into the live dev build's amx socket directory and
    /// then tripped over its own leftovers on the next run (#296).
    ///
    /// Carries the pid so two runs — or a run and its own residue — can never
    /// share a directory. The residue is left for `$TMPDIR` purging rather than
    /// swept in-process: swift-testing runs suites concurrently, so nothing
    /// inside the run can safely decide the directory is finished with.
    case test(processID: Int32)

    // Must stay byte-identical to script/runtime-profile.sh, which stamps the
    // base ids (and optional worktree suffix) into the staged Info.plist. The
    // `.test` case deliberately has no counterpart there: nothing stamps a
    // bundle for a test process, which is exactly why it needs its own case.
    static let productionBundleIdentifier = "com.interactivebuffoonery.awesomux"
    static let developmentBundleIdentifier = "com.interactivebuffoonery.awesomux.dev"

    // The bundle id can't change mid-process; resolve once so future callers
    // can't accidentally put a Bundle lookup on a hot path.
    static let current = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        // XCTest links into the test bundle and never into the app, which makes
        // it the only signal that survives both harnesses. SwiftPM runs
        // swift-testing through `swiftpm-testing-helper`, which sets none of
        // XCTest's environment variables and leaves `Bundle.main` pointing at
        // the toolchain — so neither the bundle id nor
        // `XCTestConfigurationFilePath` can tell a test run apart.
        isTestRunner: NSClassFromString("XCTestCase") != nil
    )

    static func resolve(
        bundleIdentifier: String?,
        isTestRunner: Bool = false
    ) -> AppRuntimeProfile {
        // Ahead of the bundle id on purpose: a test process is never the app,
        // whatever Info.plist an Xcode test host happens to hand it.
        if isTestRunner {
            return .test(processID: ProcessInfo.processInfo.processIdentifier)
        }
        if bundleIdentifier == productionBundleIdentifier {
            return .production
        }
        if bundleIdentifier == developmentBundleIdentifier {
            return .development(worktreeID: nil)
        }
        let prefix = developmentBundleIdentifier + "."
        if let bundleIdentifier, bundleIdentifier.hasPrefix(prefix) {
            let candidate = String(bundleIdentifier.dropFirst(prefix.count))
            if isValidWorktreeID(candidate) {
                return .development(worktreeID: candidate)
            }
        }

        // Fail isolated: a nil/unknown identity (`swift run`, a bare .build
        // binary, a test runner) is never the installed app, so it must not
        // share the installed app's session snapshot, config, daemon pins, or
        // amx socket dir.
        return .development(worktreeID: nil)
    }

    var supportDirectoryName: String {
        switch self {
        case .production: "awesoMux"
        case .development(nil): "awesoMux-dev"
        case .development(let worktreeID?): "awesoMux-dev-\(worktreeID)"
        case .test(let processID): "awesoMux-test-\(processID)"
        }
    }

    var configDirectoryName: String {
        switch self {
        case .production: "awesomux"
        case .development(nil): "awesomux-dev"
        case .development(let worktreeID?): "awesomux-dev-\(worktreeID)"
        case .test(let processID): "awesomux-test-\(processID)"
        }
    }

    var amxSocketDirectoryName: String {
        switch self {
        case .production: "amx"
        case .development(nil): "amx-dev"
        case .development(let worktreeID?): Self.socketNamespace(worktreeID: worktreeID)
        case .test(let processID): Self.testSocketNamespace(processID: processID)
        }
    }

    var environmentValue: String {
        switch self {
        case .production:
            "production"
        case .development(nil):
            "development"
        case .development(let worktreeID?):
            "development:\(worktreeID)"
        case .test(let processID):
            "test:\(processID)"
        }
    }

    /// ssh ControlMaster socket dir name under `~/.awesomux/`. Profile-split so
    /// a dev build never multiplexes over (or tears down forwards on) the
    /// installed app's masters.
    var sshControlDirectoryName: String {
        switch self {
        case .production: "ssh"
        case .development: "ssh-dev"
        // Stable, unlike the socket dir: a ControlMaster socket is only ever
        // created by a live ssh master, which the suite never spawns, so
        // there is nothing here for a later run to inherit.
        case .test: "ssh-test"
        }
    }

    var supportDirectoryURL: URL {
        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDirectoryURL(applicationSupportDirectory: applicationSupportDirectory)
    }

    func supportDirectoryURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appending(path: supportDirectoryName, directoryHint: .isDirectory)
    }

    var amxSocketDirectoryPath: String {
        amxSocketDirectoryPath(temporaryDirectory: NSTemporaryDirectory())
    }

    func amxSocketDirectoryPath(temporaryDirectory: String) -> String {
        (temporaryDirectory as NSString).appendingPathComponent(amxSocketDirectoryName)
    }

    private static func isValidWorktreeID(_ value: String) -> Bool {
        value.utf8.count == 12 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    /// Base-36 and zero-padded to exactly `amx-dev`'s width, because that width
    /// IS the ceiling: under the longest `$TMPDIR` the `sockaddr_un` budget in
    /// `AmxBackend.sessionSocketDirectory` leaves room for seven bytes and not
    /// an eighth. `suffix` keeps the low digits — pids cap at 99999 on macOS, so
    /// it never truncates today, and neighbouring pids stay distinct if a future
    /// kernel raises that ceiling.
    private static func testSocketNamespace(processID: Int32) -> String {
        let encoded = String(UInt32(bitPattern: processID), radix: 36).suffix(4)
        return "amx" + String(repeating: "0", count: 4 - encoded.count) + encoded
    }

    private static func socketNamespace(worktreeID: String) -> String {
        let hashPrefix = String(worktreeID.prefix(9))
        let value = UInt64(hashPrefix, radix: 16) ?? 0
        let encoded = String(value, radix: 36, uppercase: false)
        return String(repeating: "0", count: max(0, 7 - encoded.count)) + encoded
    }
}
