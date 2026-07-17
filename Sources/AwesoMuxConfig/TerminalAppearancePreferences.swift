import Foundation

public struct TerminalAppearancePreferences: Equatable, Sendable {
    public static let systemMonospaceFont = "system-monospace"
    public static let bundledMonoFont = "Hack Nerd Font Mono"
    public static let terminalThemeCatalog = TerminalThemeCatalog.builtIn

    /// Ghostty exposes `font-family` plus three style variants. A user
    /// `~/.config/ghostty/config` setting any of `font-family-bold`,
    /// `font-family-italic`, or `font-family-bold-italic` survives our
    /// override and produces a mixed-font terminal. Reset all four so we
    /// fully own the family stack.
    private static let ghosttyFontFamilyKeys = [
        "font-family",
        "font-family-bold",
        "font-family-italic",
        "font-family-bold-italic",
    ]
    private static let catppuccinLatteFaintOpacity = "0.95"

    public static let inheritedTerminalContextKeys = [
        // awesoMux owns this identity string; never inherit a parent's value.
        "AWESOMUX",
        "MOSHI_SESSION",
        "SSH_CLIENT",
        "SSH_CONNECTION",
        "SSH_TTY",
        "STY",
        "TMUX",
        "TMUX_PANE",
        "ZELLIJ",
    ]

    public enum EffectiveTheme: Equatable, Sendable {
        case light
        case dark
    }

    public enum TerminalColorScheme: Equatable, Sendable {
        case light
        case dark
    }

    public var monoFont: String
    public var fontSize: Double
    public var terminalBackgroundMode: AppearanceConfig.TerminalBackgroundMode
    public var terminalBackgroundColor: String
    public var terminalThemeID: String?
    public var effectiveTheme: EffectiveTheme

    public static let defaultValue = TerminalAppearancePreferences(
        monoFont: AppearanceConfig.defaultValue.monoFont,
        fontSize: AppearanceConfig.defaultValue.fontSize,
        terminalBackgroundMode: AppearanceConfig.defaultValue.terminalBackgroundMode,
        terminalBackgroundColor: AppearanceConfig.defaultValue.terminalBackgroundColor,
        terminalThemeID: AppearanceConfig.defaultValue.terminalThemeID,
        effectiveTheme: .dark
    )

    public init(
        monoFont: String = AppearanceConfig.defaultValue.monoFont,
        fontSize: Double = AppearanceConfig.defaultValue.fontSize,
        terminalBackgroundMode: AppearanceConfig.TerminalBackgroundMode = AppearanceConfig.defaultValue.terminalBackgroundMode,
        terminalBackgroundColor: String = AppearanceConfig.defaultValue.terminalBackgroundColor,
        terminalThemeID: String? = AppearanceConfig.defaultValue.terminalThemeID,
        effectiveTheme: EffectiveTheme = .dark
    ) {
        self.monoFont = monoFont
        self.fontSize = fontSize
        self.terminalBackgroundMode = terminalBackgroundMode
        self.terminalBackgroundColor =
            AppearanceConfig.normalizedTerminalBackgroundColor(terminalBackgroundColor)
            ?? AppearanceConfig.defaultValue.terminalBackgroundColor
        self.terminalThemeID = terminalThemeID
        self.effectiveTheme = effectiveTheme
    }

    public init(appearance: AppearanceConfig, effectiveTheme: EffectiveTheme = .dark) {
        self.init(
            monoFont: appearance.monoFont,
            fontSize: appearance.fontSize,
            terminalBackgroundMode: appearance.terminalBackgroundMode,
            terminalBackgroundColor: appearance.terminalBackgroundColor,
            terminalThemeID: appearance.terminalThemeID,
            effectiveTheme: effectiveTheme
        )
    }

    public var ghosttyFontSize: Float {
        let safeFontSize = fontSize.isFinite ? fontSize : Self.defaultValue.fontSize
        return Float(min(max(safeFontSize, 6), 72))
    }

    public var terminalColorScheme: TerminalColorScheme {
        switch terminalIdentityTheme {
        case .light: .light
        case .dark: .dark
        }
    }

    public var terminalThemeProvider: any TerminalThemeProvider {
        Self.terminalThemeCatalog.provider(for: terminalThemeID)
    }

    /// The app's marketing version, advertised as `TERM_PROGRAM_VERSION`.
    /// Resolved once from the main bundle; nil outside a real app bundle
    /// (SwiftPM test runners, bare CLI runs).
    private static let appVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    public var terminalSpawnEnvironment: [String: String] {
        // Identity is awesoMux (ADR-0011 follow-up: process-tree tools see the
        // `amx` daemon, but env-trusting tools should name the real terminal).
        // Capability stays `TERM=xterm-ghostty` — that's the signal CLI tools
        // use for Ghostty features like terminal graphics.
        var environment = [
            "AWESOMUX": "1",
            "COLORFGBG": terminalColorFGBG,
            "COLORTERM": "truecolor",
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "awesoMux",
        ]
        // Pair the identity with awesoMux's own version. libghostty injects
        // TERM_PROGRAM_VERSION=<ghostty version> before applying this dict
        // (vendor/ghostty src/termio/Exec.zig, env_override wins), so this key
        // must ALWAYS be set — otherwise the ghostty version sits next to the
        // awesoMux name. Outside an app bundle (SwiftPM test runners, bare CLI
        // runs) there's no version to advertise; an empty value reads as unset
        // to `[[ -n … ]]`-style probes, which beats lying with ghostty's.
        environment["TERM_PROGRAM_VERSION"] = Self.appVersion ?? ""
        return environment
    }

    /// Merges `environment` with awesoMux's terminal-identity environment,
    /// with awesoMux's identity keys and inherited container-terminal
    /// markers always winning over caller-supplied values.
    ///
    /// This is a deliberate public-API contract — awesoMux owns the terminal
    /// identity it advertises to spawned shells because letting a stale
    /// `COLORFGBG=0;15` reach a dark terminal causes downstream TUIs like
    /// Claude Code to render with the wrong contrast. `TERM=xterm-ghostty`
    /// remains part of that identity so CLI tools can detect Ghostty
    /// capabilities such as terminal graphics. Likewise, inherited
    /// `TMUX`/`ZELLIJ`/SSH/mosh markers describe the terminal that launched
    /// awesoMux, not the fresh pane inside awesoMux; leaking them changes
    /// shell startup behavior such as fastfetch graphics selection. `NO_COLOR`
    /// is intentionally preserved because it is a user-facing color opt-out,
    /// not parent-terminal context. Development launchers that inject stale
    /// `NO_COLOR` should sanitize their own launch environment instead.
    /// Do not relax to "caller wins" without a real downstream need; if one
    /// ever appears (e.g. headless agent runners that want `TERM=dumb`),
    /// introduce a separate API surface for it rather than weakening this
    /// guarantee.
    public func environmentForTerminalSpawn(
        merging environment: [String: String],
        inheritedEnvironment: [String: String] = [:]
    ) -> [String: String] {
        var merged = environment
        for key in Self.inheritedTerminalContextKeys {
            merged.removeValue(forKey: key)
        }
        // Locale fallback. A GUI/launchd-spawned awesoMux inherits no
        // `LANG`/`LC_*`, so child shells land in the C locale, where macOS
        // libc's `iswprint`/`wcwidth` reject every non-ASCII codepoint. zsh's
        // line editor then echoes typed emoji as `<0001f973>` placeholders.
        // (Output is unaffected — libghostty owns its own width tables.) Inject
        // a UTF-8 ctype *only* when the inherited environment provides none, so
        // a user who already exports a UTF-8 locale is untouched. See
        // docs/debugging/emoji-input-echo-iswprint.md.
        for (key, value) in Self.localeCtypeFallback(inheritedEnvironment: inheritedEnvironment)
        where merged[key] == nil {
            merged[key] = value
        }
        // Defense-in-depth child-shell hygiene: drop the GHOSTTY_*/CMUX_*
        // families so a parent terminal's bundle pointers/sockets don't reach
        // the spawned shell. NOTE: this is NOT what fixes the quit-confirm bug —
        // libghostty reads GHOSTTY_RESOURCES_DIR from its own *process* env
        // (sanitized in `sanitizeInheritedTerminalContextFromProcessEnvironment`),
        // not from this per-surface dict. Current callers pass only AWESOMUX_*
        // keys here, so today this strips nothing; it guards a future caller
        // that merges the process environment.
        merged = merged.filter { key, _ in
            !key.hasPrefix("GHOSTTY_") && !key.hasPrefix("CMUX_")
        }
        for (key, value) in terminalSpawnEnvironment {
            merged[key] = value
        }
        return merged
    }

    /// The minimal locale keys needed to give a spawned shell a UTF-8 character
    /// type when the inherited environment doesn't already resolve to one.
    /// Returns `[:]` when a UTF-8 ctype is already in effect, so it never
    /// overrides a working UTF-8 locale and never fights an explicit `LC_ALL`.
    ///
    /// It *does* replace a non-UTF-8 `LC_CTYPE`/`LANG` (when no `LC_ALL` is set)
    /// with `LC_CTYPE=UTF-8` — that broken ctype is exactly the case this fixes,
    /// and `LC_ALL` remains the escape hatch for anyone who genuinely wants a
    /// non-UTF-8 ctype in a pane.
    ///
    /// Resolution mirrors POSIX precedence `LC_ALL > LC_CTYPE > LANG`:
    /// - If the effective ctype already names a UTF-8 codeset, do nothing.
    /// - If `LC_ALL` is set to a non-UTF-8 value, do nothing — `LC_ALL` shadows
    ///   `LC_CTYPE`, so our injection would be inert anyway, and an explicit
    ///   `LC_ALL=C` is a deliberate user choice we don't fight.
    /// - Otherwise inject `LC_CTYPE=UTF-8`. macOS treats bare `UTF-8` as a
    ///   locale-independent codeset, so we fix character classification without
    ///   imposing a language/region (`en_US`) the user never asked for.
    public static func localeCtypeFallback(
        inheritedEnvironment: [String: String]
    ) -> [String: String] {
        func nonEmpty(_ key: String) -> String? {
            guard let value = inheritedEnvironment[key], !value.isEmpty else {
                return nil
            }
            return value
        }

        let lcAll = nonEmpty("LC_ALL")
        let effectiveCtype = lcAll ?? nonEmpty("LC_CTYPE") ?? nonEmpty("LANG")

        if let effectiveCtype, isUTF8Codeset(effectiveCtype) {
            return [:]
        }
        if lcAll != nil {
            return [:]
        }
        return ["LC_CTYPE": "UTF-8"]
    }

    /// True when a locale string names the UTF-8 codeset, e.g. `en_US.UTF-8`,
    /// `UTF-8`, or `C.UTF-8`. macOS spells it `UTF-8`; accept the unhyphenated
    /// `UTF8` form too since some environments export it.
    private static func isUTF8Codeset(_ locale: String) -> Bool {
        let upper = locale.uppercased()
        return upper.contains("UTF-8") || upper.contains("UTF8")
    }

    public var ghosttyOverrideConfigContents: String {
        var lines = [
            "font-size = \(Self.formattedFontSize(ghosttyFontSize))"
        ]

        if let fontFamily = ghosttyFontFamily {
            // Reset all four family keys before setting our pick so any
            // style-specific families from a user `~/.config/ghostty/config`
            // don't leak through and produce a mixed-font terminal.
            // Ghostty derives bold/italic from the regular family when the
            // style-specific lists are empty, which is what we want.
            for key in Self.ghosttyFontFamilyKeys {
                lines.append("\(key) = \(Self.ghosttyQuotedString(""))")
            }
            lines.append("font-family = \(Self.ghosttyQuotedString(fontFamily))")
        }

        if let background = ghosttyBackgroundColor {
            lines.append(contentsOf: ghosttyColorConfigLines)
            if let faintOpacity = ghosttyFaintOpacity {
                lines.append("faint-opacity = \(faintOpacity)")
            }
            lines.append("background = \(background)")
        }

        return lines.joined(separator: "\n")
    }

    public var ghosttyBackgroundColor: String? {
        switch terminalBackgroundMode {
        case .ghostty:
            nil
        case .catppuccinTheme:
            terminalThemeProvider.background(for: effectiveTheme)
        case .custom:
            // Re-normalize at emit time. `terminalBackgroundColor` is a
            // public var (no `private(set)`) so post-init assignment can
            // bypass the init-time normalize. Re-running it here makes the
            // libghostty boundary self-protecting regardless of how the
            // struct gets mutated.
            AppearanceConfig.normalizedTerminalBackgroundColor(terminalBackgroundColor)
                ?? AppearanceConfig.defaultValue.terminalBackgroundColor
        }
    }

    private var ghosttyFaintOpacity: String? {
        guard ghosttyBackgroundColor != nil,
            terminalIdentityTheme == .light
        else {
            return nil
        }

        return Self.catppuccinLatteFaintOpacity
    }

    public var diagnosticSummary: TerminalAppearanceDiagnosticSummary {
        let ownsColors = ghosttyBackgroundColor != nil
        let colors = terminalDiagnosticColors(for: terminalIdentityTheme)

        return TerminalAppearanceDiagnosticSummary(
            backgroundMode: terminalBackgroundMode.rawValue,
            effectiveTheme: effectiveTheme.logValue,
            terminalColorScheme: terminalColorScheme.logValue,
            awesoMuxOwnsColors: ownsColors,
            background: ghosttyBackgroundColor ?? "ghostty-owned",
            foreground: ownsColors ? colors.foreground : "ghostty-owned",
            palette0: ownsColors ? colors.palette0 : "ghostty-owned",
            palette15: ownsColors ? colors.palette15 : "ghostty-owned",
            faintOpacity: ghosttyFaintOpacity ?? "ghostty-default"
        )
    }

    // Background tokens only — Catppuccin's accent palette (Mauve, Peach,
    // etc.) was intentionally dropped from this list because they're accent
    // tokens, not background tokens. Picking Peach as a background gives
    // ~1.6:1 contrast against a typical Catppuccin foreground — a
    // foot-gun the picker shouldn't hand to users without a contrast
    // warning UI we don't currently have.
    public static var catppuccinBackgroundPresets: [(name: String, hex: String)] {
        CatppuccinThemeProvider.backgroundPresets
    }

    /// The font family actually handed to libghostty, or `nil` when no
    /// override is emitted (system-monospace sentinel, empty, or a value
    /// rejected at the config boundary). Public because spoken/status
    /// surfaces (the VoiceOver commit announcement) must report the applied
    /// value, not the raw stored `monoFont` — the two diverge for
    /// hand-edited configs.
    public var ghosttyFontFamily: String? {
        let trimmed = monoFont.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject ALL C0/C1 control characters, not just newlines and NUL.
        // Real font family names never contain tab, BEL, DEL, or other
        // control bytes; passing them through to libghostty's config
        // parser is unnecessary attack surface (defense in depth).
        guard !trimmed.isEmpty,
            trimmed.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20
                    && scalar.value != 0x7F
                    && !(0x80...0x9F).contains(scalar.value)
            })
        else {
            return nil
        }

        // The system-monospace sentinel means "let Ghostty resolve the
        // default font family"; emit no override so the runtime falls
        // back to whatever the user (or Ghostty's own default) specifies.
        // Forcing `SF Mono` here would silently fail on installs where
        // CoreText can't resolve that family.
        if trimmed == Self.systemMonospaceFont {
            return nil
        }

        return trimmed
    }

    private var ghosttyColorConfigLines: [String] {
        Self.terminalThemeCatalog.ghosttyColorConfigLines(
            for: colorConfigThemeID,
            theme: terminalIdentityTheme
        )
    }

    private var colorConfigThemeID: String? {
        switch terminalBackgroundMode {
        case .ghostty, .catppuccinTheme:
            terminalThemeID
        case .custom:
            TerminalThemeCatalog.catppuccinID
        }
    }

    private var terminalIdentityTheme: EffectiveTheme {
        switch terminalBackgroundMode {
        case .ghostty, .catppuccinTheme:
            effectiveTheme
        case .custom:
            customBackgroundTheme
        }
    }

    private var terminalColorFGBG: String {
        switch terminalIdentityTheme {
        case .light: "0;15"
        case .dark: "15;0"
        }
    }

    private var customBackgroundTheme: EffectiveTheme {
        let background =
            AppearanceConfig.normalizedTerminalBackgroundColor(terminalBackgroundColor)
            ?? AppearanceConfig.defaultValue.terminalBackgroundColor
        return Self.isLightHex(background) ? .light : .dark
    }

    private func terminalDiagnosticColors(
        for theme: EffectiveTheme
    ) -> (foreground: String, palette0: String, palette15: String) {
        let provider = Self.terminalThemeCatalog.provider(for: colorConfigThemeID)
        let ansi16 = provider.ansi16(for: theme)
        let foreground = provider.foreground(for: theme)
        return (
            foreground,
            ansi16.indices.contains(0) ? ansi16[0] : foreground,
            ansi16.indices.contains(15) ? ansi16[15] : foreground
        )
    }

    private static func isLightHex(_ hex: String) -> Bool {
        guard let components = rgbComponents(hex) else {
            return false
        }
        // WCAG relative luminance — gamma-expand each sRGB channel before
        // applying Rec. 709 coefficients. Without the expansion a mid-gray
        // like #808080 yields ~0.502 and gets classified light, when its
        // true relative luminance is ~0.216 (dark). 0.5 threshold matches
        // the WCAG "darker than mid-gray" intuition.
        let luminance =
            0.2126 * srgbToLinear(components.red)
            + 0.7152 * srgbToLinear(components.green)
            + 0.0722 * srgbToLinear(components.blue)
        return luminance > 0.5
    }

    private static func srgbToLinear(_ channel: Double) -> Double {
        channel <= 0.04045
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func rgbComponents(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
            let value = UInt32(trimmed, radix: 16)
        else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return (red, green, blue)
    }

    private static func formattedFontSize(_ size: Float) -> String {
        let doubleSize = Double(size)
        if doubleSize.rounded() == doubleSize {
            return "\(Int(doubleSize))"
        }

        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), doubleSize)
    }

    private static func ghosttyQuotedString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped.append(#"\""#)
            case "\\":
                escaped.append(#"\\"#)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return #""\#(escaped)""#
    }
}

private extension TerminalAppearancePreferences.EffectiveTheme {
    var logValue: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        }
    }
}

private extension TerminalAppearancePreferences.TerminalColorScheme {
    var logValue: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        }
    }
}
