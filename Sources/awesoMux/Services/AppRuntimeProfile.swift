import Foundation

enum AppRuntimeProfile: Equatable, Sendable {
    case production
    case development(worktreeID: String?)

    // Must stay byte-identical to script/runtime-profile.sh, which stamps the
    // base ids (and optional worktree suffix) into the staged Info.plist.
    static let productionBundleIdentifier = "com.interactivebuffoonery.awesomux"
    static let developmentBundleIdentifier = "com.interactivebuffoonery.awesomux.dev"

    // The bundle id can't change mid-process; resolve once so future callers
    // can't accidentally put a Bundle lookup on a hot path.
    static let current = resolve(bundleIdentifier: Bundle.main.bundleIdentifier)

    static func resolve(bundleIdentifier: String?) -> AppRuntimeProfile {
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
        }
    }

    var configDirectoryName: String {
        switch self {
        case .production: "awesomux"
        case .development(nil): "awesomux-dev"
        case .development(let worktreeID?): "awesomux-dev-\(worktreeID)"
        }
    }

    var amxSocketDirectoryName: String {
        switch self {
        case .production: "amx"
        case .development(nil): "amx-dev"
        case .development(let worktreeID?): Self.socketNamespace(worktreeID: worktreeID)
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
        }
    }

    /// ssh ControlMaster socket dir name under `~/.awesomux/`. Profile-split so
    /// a dev build never multiplexes over (or tears down forwards on) the
    /// installed app's masters.
    var sshControlDirectoryName: String {
        switch self {
        case .production: "ssh"
        case .development: "ssh-dev"
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

    private static func socketNamespace(worktreeID: String) -> String {
        let hashPrefix = String(worktreeID.prefix(9))
        let value = UInt64(hashPrefix, radix: 16) ?? 0
        let encoded = String(value, radix: 36, uppercase: false)
        return String(repeating: "0", count: max(0, 7 - encoded.count)) + encoded
    }
}
