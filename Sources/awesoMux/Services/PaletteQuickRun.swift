import Foundation

enum PaletteQuickRunCommitSurface: Equatable, Sendable {
    case toast
    case floatingPanel
    case newTab

    var title: String {
        switch self {
        case .toast:
            "Run as Toast"
        case .floatingPanel:
            "Run in Floating Panel"
        case .newTab:
            "Run in New Tab"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .toast:
            "Return runs as toast"
        case .floatingPanel:
            "Command Return runs in floating panel"
        case .newTab:
            "Command Shift Return runs in a new tab"
        }
    }
}

struct PaletteQuickRunResult: Identifiable, Equatable, Sendable {
    let command: String
    let executable: String
    let resolvedExecutablePath: String

    var id: String { "quickRun.\(command)" }
    var title: String { command }
    var subtitle: String { "Quick run · \(executable)" }
}

enum PaletteQuickRunDetector {
    static let reservedPrefixes: Set<Character> = [">", "@", "?"]

    static func quickRun(
        for rawQuery: String,
        searchPath: String = ProcessCommandRunner.defaultToolPath,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PaletteQuickRunResult? {
        let command = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = command.first,
              !reservedPrefixes.contains(first),
              let token = leadingToken(in: command),
              isShellyToken(token),
              let executableURL = ProcessCommandRunner.resolveExecutable(
                token,
                searchPath: searchPath,
                homeDirectoryURL: homeDirectoryURL
              ) else {
            return nil
        }

        return PaletteQuickRunResult(
            command: command,
            executable: token,
            resolvedExecutablePath: executableURL.path
        )
    }

    private static func leadingToken(in command: String) -> String? {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func isShellyToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-" || character == ".")
        }
    }
}
