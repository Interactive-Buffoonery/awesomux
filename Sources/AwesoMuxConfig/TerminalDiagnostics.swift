import Foundation

public enum TerminalDiagnosticsConfiguration {
    public static let environmentKey = "AWESOMUX_TERMINAL_DIAGNOSTICS"

    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}

public struct TerminalDiagnosticEnvironmentSnapshot: Equatable, Sendable {
    public static let capturedKeys = [
        "TERM",
        "COLORTERM",
        "COLORFGBG",
        "NO_COLOR",
        "FORCE_COLOR",
        "TERM_PROGRAM",
        "TMUX",
        "TMUX_PANE",
        "ZELLIJ",
        "STY",
        "MOSHI_SESSION",
        "SSH_CONNECTION",
        "SSH_CLIENT",
        "SSH_TTY"
    ]

    public let term: String
    public let colorTerm: String
    public let colorFGBG: String
    public let noColor: String
    public let forceColor: String
    public let termProgram: String
    public let tmux: String
    public let tmuxPane: String
    public let zellij: String
    public let screen: String
    public let moshiSession: String
    public let sshConnection: String
    public let sshClient: String
    public let sshTTY: String

    public init(environment: [String: String]) {
        self.term = Self.sanitizedValue(environment["TERM"])
        self.colorTerm = Self.sanitizedValue(environment["COLORTERM"])
        self.colorFGBG = Self.sanitizedValue(environment["COLORFGBG"])
        self.noColor = Self.presenceValue(environment["NO_COLOR"])
        self.forceColor = Self.forceColorValue(environment["FORCE_COLOR"])
        self.termProgram = Self.sanitizedValue(environment["TERM_PROGRAM"])
        self.tmux = Self.presenceValue(environment["TMUX"])
        self.tmuxPane = Self.presenceValue(environment["TMUX_PANE"])
        self.zellij = Self.presenceValue(environment["ZELLIJ"])
        self.screen = Self.presenceValue(environment["STY"])
        self.moshiSession = Self.presenceValue(environment["MOSHI_SESSION"])
        self.sshConnection = Self.presenceValue(environment["SSH_CONNECTION"])
        self.sshClient = Self.presenceValue(environment["SSH_CLIENT"])
        self.sshTTY = Self.presenceValue(environment["SSH_TTY"])
    }

    public var logFields: String {
        [
            "term=\(term)",
            "colorterm=\(colorTerm)",
            "colorfgbg=\(colorFGBG)",
            "no_color=\(noColor)",
            "force_color=\(forceColor)",
            "term_program=\(termProgram)",
            "tmux=\(tmux)",
            "tmux_pane=\(tmuxPane)",
            "zellij=\(zellij)",
            "sty=\(screen)",
            "moshi_session=\(moshiSession)",
            "ssh_connection=\(sshConnection)",
            "ssh_client=\(sshClient)",
            "ssh_tty=\(sshTTY)"
        ].joined(separator: " ")
    }

    private static func forceColorValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return presenceValue(value)
        }

        let sanitized = sanitizedValue(value)
        switch sanitized {
        case "0", "1", "2", "3", "true", "false":
            return sanitized
        case "redacted":
            return "redacted"
        default:
            return "set"
        }
    }

    private static func presenceValue(_ value: String?) -> String {
        guard let value else { return "unset" }
        return value.isEmpty ? "empty" : "set"
    }

    private static func sanitizedValue(_ value: String?) -> String {
        guard let value else { return "unset" }
        guard !value.isEmpty else { return "empty" }
        guard !value.contains("/"), !value.contains("\\") else {
            return "redacted"
        }

        var sanitized = ""
        sanitized.reserveCapacity(min(value.count, 80))
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39,
                 0x41 ... 0x5A,
                 0x61 ... 0x7A:
                sanitized.unicodeScalars.append(scalar)
            case 0x2B, 0x2D, 0x2E, 0x3A, 0x3B, 0x5F:
                sanitized.unicodeScalars.append(scalar)
            default:
                sanitized.append("_")
            }

            if sanitized.count >= 80 {
                break
            }
        }

        return sanitized.isEmpty ? "empty" : sanitized
    }
}

public struct TerminalAppearanceDiagnosticSummary: Equatable, Sendable {
    public let backgroundMode: String
    public let effectiveTheme: String
    public let terminalColorScheme: String
    public let awesoMuxOwnsColors: Bool
    public let background: String
    public let foreground: String
    public let palette0: String
    public let palette15: String
    public let faintOpacity: String

    public init(
        backgroundMode: String,
        effectiveTheme: String,
        terminalColorScheme: String,
        awesoMuxOwnsColors: Bool,
        background: String,
        foreground: String,
        palette0: String,
        palette15: String,
        faintOpacity: String
    ) {
        self.backgroundMode = backgroundMode
        self.effectiveTheme = effectiveTheme
        self.terminalColorScheme = terminalColorScheme
        self.awesoMuxOwnsColors = awesoMuxOwnsColors
        self.background = background
        self.foreground = foreground
        self.palette0 = palette0
        self.palette15 = palette15
        self.faintOpacity = faintOpacity
    }

    public var logFields: String {
        [
            "background_mode=\(backgroundMode)",
            "effective_theme=\(effectiveTheme)",
            "terminal_color_scheme=\(terminalColorScheme)",
            "awesomux_owns_colors=\(awesoMuxOwnsColors)",
            "background=\(background)",
            "foreground=\(foreground)",
            "palette0=\(palette0)",
            "palette15=\(palette15)",
            "faint_opacity=\(faintOpacity)"
        ].joined(separator: " ")
    }
}
