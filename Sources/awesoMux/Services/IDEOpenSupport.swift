import AppKit
import AwesoMuxCore
import Foundation

enum PathBarOpenTargetAction: Equatable {
    case showMenu
    case revealInFinder

    static func forClick(modifierFlags: NSEvent.ModifierFlags) -> Self {
        modifierFlags.contains(.command) ? .revealInFinder : .showMenu
    }
}

struct KnownIDE: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
}

struct InstalledIDE: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let applicationURL: URL
}

enum InstalledIDEDiscovery {
    static let knownIDEs: [KnownIDE] = [
        KnownIDE(displayName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"),
        KnownIDE(displayName: "Visual Studio Code - Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders"),
        KnownIDE(displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        KnownIDE(displayName: "Windsurf", bundleIdentifier: "com.exafunction.windsurf"),
        KnownIDE(displayName: "Zed", bundleIdentifier: "dev.zed.Zed"),
        KnownIDE(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        KnownIDE(displayName: "Android Studio", bundleIdentifier: "com.google.android.studio"),
        KnownIDE(displayName: "Sublime Text", bundleIdentifier: "com.sublimetext.4"),
        KnownIDE(displayName: "BBEdit", bundleIdentifier: "com.barebones.bbedit"),
        KnownIDE(displayName: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij"),
        KnownIDE(displayName: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm"),
        KnownIDE(displayName: "PyCharm", bundleIdentifier: "com.jetbrains.PyCharm"),
        KnownIDE(displayName: "CLion", bundleIdentifier: "com.jetbrains.CLion"),
        KnownIDE(displayName: "GoLand", bundleIdentifier: "com.jetbrains.GoLand"),
        KnownIDE(displayName: "Rider", bundleIdentifier: "com.jetbrains.rider"),
        KnownIDE(displayName: "RustRover", bundleIdentifier: "com.jetbrains.rustrover"),
        KnownIDE(displayName: "PhpStorm", bundleIdentifier: "com.jetbrains.PhpStorm"),
        KnownIDE(displayName: "RubyMine", bundleIdentifier: "com.jetbrains.RubyMine"),
        KnownIDE(displayName: "DataSpell", bundleIdentifier: "com.jetbrains.dataspell")
    ]

    static func installed(
        resolveApplicationURL: (String) -> URL?
    ) -> [InstalledIDE] {
        installed(extraBundleIdentifiers: [], resolveApplicationURL: resolveApplicationURL)
    }

    /// Known editors plus any user-added `extraBundleIdentifiers` that still
    /// resolve to an installed app. The display name for an extra id comes from
    /// the allowlist when it matches one, otherwise from the app bundle itself
    /// (last-path-component fallback) so an arbitrary `.app` reads cleanly.
    static func installed(
        extraBundleIdentifiers: [String],
        resolveApplicationURL: (String) -> URL?,
        displayName: (URL) -> String? = { _ in nil }
    ) -> [InstalledIDE] {
        let knownByID = Dictionary(
            knownIDEs.map { ($0.bundleIdentifier, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedIDs = knownIDEs.map(\.bundleIdentifier)
            + extraBundleIdentifiers.filter { knownByID[$0] == nil }
        var seen = Set<String>()
        return orderedIDs.compactMap { bundleID in
            guard seen.insert(bundleID).inserted,
                  let applicationURL = resolveApplicationURL(bundleID) else {
                return nil
            }
            let name = knownByID[bundleID]
                ?? displayName(applicationURL)
                ?? applicationURL.deletingPathExtension().lastPathComponent
            return InstalledIDE(
                displayName: name,
                bundleIdentifier: bundleID,
                applicationURL: applicationURL
            )
        }
    }

    /// A user-facing name for an app bundle: its `CFBundleDisplayName` /
    /// `CFBundleName`, falling back to the file name without `.app`.
    static func bundleDisplayName(for applicationURL: URL) -> String? {
        guard let bundle = Bundle(url: applicationURL) else {
            return nil
        }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
    }
}

enum IDEChoice {
    /// Orders installed IDEs by the user's saved priority. Installed IDEs whose
    /// bundle id appears in `priority` come first, in `priority` order; any
    /// remaining installed IDEs follow in their existing `knownIDEs` order. An
    /// empty or partial `priority` still yields the full installed list, so the
    /// default (`ordered(...).first`) is always well-defined.
    static func ordered(
        installed: [InstalledIDE],
        priority: [String]
    ) -> [InstalledIDE] {
        let byBundleID = Dictionary(
            installed.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var result: [InstalledIDE] = []
        for bundleID in priority {
            guard let ide = byBundleID[bundleID], seen.insert(bundleID).inserted else {
                continue
            }
            result.append(ide)
        }
        for ide in installed where seen.insert(ide.bundleIdentifier).inserted {
            result.append(ide)
        }
        return result
    }

    enum NextStep: Equatable {
        case open(InstalledIDE)
        case choose(preselectedBundleIdentifier: String?)
        case unavailable
    }

    /// `ordered` must already be `ordered(installed:priority:)`; the default is
    /// its first element.
    static func nextStep(ordered: [InstalledIDE]) -> NextStep {
        switch ordered.count {
        case 0:
            return .unavailable
        case 1:
            return .open(ordered[0])
        default:
            return .choose(preselectedBundleIdentifier: ordered.first?.bundleIdentifier)
        }
    }
}

enum IDEOpenTarget {
    static func isEligible(session: TerminalSession) -> Bool {
        guard let activePane = session.activePane else {
            return false
        }
        return activePane.remoteHost == nil
            && ExecutionContext(plan: activePane.executionPlan)
                .capability(.inspectLocalFilesystem).isAllowed
    }

    static func targetURL(
        from model: TerminalPathBarModel,
        activeWorkingDirectory: String,
        homeDirectory: URL = TerminalPathBarModel.defaultHomeDirectory
    ) -> URL? {
        let activePath = canonicalizedActiveWorkingDirectory(
            activeWorkingDirectory,
            homeDirectory: homeDirectory
        )
        if let validatedRepoRootPath = model.validatedRepoRootPath {
            guard activePath == validatedRepoRootPath
                    || activePath.hasPrefix(validatedRepoRootPath + "/") else {
                return nil
            }
            return targetURL(path: validatedRepoRootPath)
        }

        guard model.copyPath == activePath else {
            return nil
        }
        return targetURL(path: model.copyPath)
    }

    private static func canonicalizedActiveWorkingDirectory(
        _ activeWorkingDirectory: String,
        homeDirectory: URL
    ) -> String {
        let expanded: String
        if activeWorkingDirectory == "~" {
            expanded = homeDirectory.path
        } else if activeWorkingDirectory.hasPrefix("~/") {
            expanded = homeDirectory
                .appending(path: String(activeWorkingDirectory.dropFirst(2)))
                .path
        } else {
            expanded = activeWorkingDirectory
        }
        return WorkingDirectoryValidator.canonicalizedPath(expanded)
    }

    private static func targetURL(path: String) -> URL? {
        guard let validated = WorkingDirectoryValidator.validatedStartupDirectory(path) else {
            return nil
        }
        return URL(fileURLWithPath: validated, isDirectory: true)
    }

    static func resolve(
        session: TerminalSession,
        homeDirectory: URL = TerminalPathBarModel.defaultHomeDirectory
    ) async -> URL? {
        guard isEligible(session: session) else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            let activeWorkingDirectory = session.activePane?.workingDirectory
                ?? session.workingDirectory
            let model = TerminalPathBarModel.make(
                session: session,
                homeDirectory: homeDirectory
            )
            return targetURL(
                from: model,
                activeWorkingDirectory: activeWorkingDirectory,
                homeDirectory: homeDirectory
            )
        }.value
    }
}
