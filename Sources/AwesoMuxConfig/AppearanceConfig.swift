public struct AppearanceConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultTheme> public var theme: Theme
    @TOMLDefault<DefaultAccent> public var accent: Accent
    @TOMLDefault<DefaultUIFont> public var uiFont: String
    @TOMLDefault<DefaultMonoFont> public var monoFont: String
    @TOMLDefault<DefaultFontSize> public var fontSize: Double
    /// Chrome text-size multiplier (INT-237). macOS has no Dynamic Type slider
    /// for app UI, so awesoMux ships its own; this factor drives `@ScaledMetric`
    /// via `AwTextScale`. 1.0 is parity with the unscaled tokens.
    @TOMLDefault<DefaultUITextScale> public var uiTextScale: Double
    @TOMLDefault<DefaultGlowStrength> public var glowStrength: Double
    @TOMLDefault<DefaultCRTScanlines> public var crtScanlines: Bool
    @TOMLDefault<DefaultCursorGlow> public var cursorGlow: Bool
    @TOMLDefault<DefaultAlwaysShowJumpNumbers> public var alwaysShowJumpNumbers: Bool
    @TOMLDefault<DefaultSidebarPosition> public var sidebarPosition: SidebarPosition
    @TOMLDefault<DefaultTerminalThemeID> public var terminalThemeID: String?
    @TOMLDefault<DefaultTerminalBackgroundMode> public var terminalBackgroundMode: TerminalBackgroundMode
    @TOMLDefault<DefaultTerminalBackgroundColor> public var terminalBackgroundColor: String

    public static let defaultValue = AppearanceConfig()

    public init(
        theme: Theme = DefaultTheme.defaultValue,
        accent: Accent = DefaultAccent.defaultValue,
        uiFont: String = DefaultUIFont.defaultValue,
        monoFont: String = DefaultMonoFont.defaultValue,
        fontSize: Double = DefaultFontSize.defaultValue,
        uiTextScale: Double = DefaultUITextScale.defaultValue,
        glowStrength: Double = DefaultGlowStrength.defaultValue,
        crtScanlines: Bool = DefaultCRTScanlines.defaultValue,
        cursorGlow: Bool = DefaultCursorGlow.defaultValue,
        alwaysShowJumpNumbers: Bool = DefaultAlwaysShowJumpNumbers.defaultValue,
        sidebarPosition: SidebarPosition = DefaultSidebarPosition.defaultValue,
        terminalThemeID: String? = DefaultTerminalThemeID.defaultValue,
        terminalBackgroundMode: TerminalBackgroundMode = DefaultTerminalBackgroundMode.defaultValue,
        terminalBackgroundColor: String = DefaultTerminalBackgroundColor.defaultValue
    ) {
        self.theme = theme
        self.accent = accent
        self.uiFont = uiFont
        self.monoFont = monoFont
        self.fontSize = fontSize
        self.uiTextScale = uiTextScale
        self.glowStrength = glowStrength
        self.crtScanlines = crtScanlines
        self.cursorGlow = cursorGlow
        self.alwaysShowJumpNumbers = alwaysShowJumpNumbers
        self.sidebarPosition = sidebarPosition
        self.terminalThemeID = terminalThemeID
        self.terminalBackgroundMode = terminalBackgroundMode
        self.terminalBackgroundColor = terminalBackgroundColor
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case theme
        case accent
        case uiFont = "ui_font"
        case monoFont = "mono_font"
        case fontSize = "font_size"
        case uiTextScale = "ui_text_scale"
        case glowStrength = "glow_strength"
        case crtScanlines = "crt_scanlines"
        case cursorGlow = "cursor_glow"
        case alwaysShowJumpNumbers = "always_show_jump_numbers"
        case sidebarPosition = "sidebar_position"
        case terminalThemeID = "terminal_theme_id"
        case terminalBackgroundMode = "terminal_background_mode"
        case terminalBackgroundColor = "terminal_background_color"
    }

    static let ownedTOMLKeys: Set<String> = [
        CodingKeys.theme.rawValue,
        CodingKeys.accent.rawValue,
        CodingKeys.uiFont.rawValue,
        CodingKeys.monoFont.rawValue,
        CodingKeys.fontSize.rawValue,
        CodingKeys.uiTextScale.rawValue,
        CodingKeys.glowStrength.rawValue,
        CodingKeys.crtScanlines.rawValue,
        CodingKeys.cursorGlow.rawValue,
        CodingKeys.alwaysShowJumpNumbers.rawValue,
        CodingKeys.sidebarPosition.rawValue,
        CodingKeys.terminalThemeID.rawValue,
        CodingKeys.terminalBackgroundMode.rawValue,
        CodingKeys.terminalBackgroundColor.rawValue,
    ]
}

public struct DefaultTheme: DefaultProvider {
    public static let defaultValue: AppearanceConfig.Theme = .system
}

public struct DefaultAccent: DefaultProvider {
    public static let defaultValue: AppearanceConfig.Accent = .peach
}

public struct DefaultUIFont: DefaultProvider {
    public static let defaultValue = "Geist"
}

public struct DefaultMonoFont: DefaultProvider {
    public static let defaultValue = TerminalAppearancePreferences.bundledMonoFont
}

public struct DefaultFontSize: DefaultProvider {
    public static let defaultValue = 13.0
}

public struct DefaultUITextScale: DefaultProvider {
    public static let defaultValue = 1.0
}

public struct DefaultGlowStrength: DefaultProvider {
    public static let defaultValue = 0.65
}

public struct DefaultCRTScanlines: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultCursorGlow: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultAlwaysShowJumpNumbers: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultSidebarPosition: DefaultProvider {
    public static let defaultValue: AppearanceConfig.SidebarPosition = .left
}

public struct DefaultTerminalThemeID: DefaultProvider {
    public static let defaultValue: String? = nil
}

public struct DefaultTerminalBackgroundMode: DefaultProvider {
    public static let defaultValue: AppearanceConfig.TerminalBackgroundMode = .ghostty
}

public struct DefaultTerminalBackgroundColor: DefaultProvider {
    public static let defaultValue = "#1e1e2e"
}

public extension AppearanceConfig {
    enum Theme: String, Codable, CaseIterable, Equatable, Sendable {
        case system
        case light
        case dark
    }

    enum Accent: String, Codable, CaseIterable, Equatable, Sendable {
        case peach
        case mauve
        case sapphire
        case green
    }

    enum SidebarPosition: String, Codable, CaseIterable, Equatable, Sendable {
        case left
        case right
    }

    enum TerminalBackgroundMode: String, Codable, CaseIterable, Equatable, Sendable {
        case ghostty
        case catppuccinTheme = "catppuccin_theme"
        case custom
    }
}

extension AppearanceConfig {
    func validate() throws(ConfigLoadError) {
        // Match the runtime clamp in `TerminalAppearancePreferences.ghosttyFontSize`
        // so values that survive validation also survive the libghostty boundary
        // without silent renormalization.
        guard (6.0...72.0).contains(fontSize) else {
            throw .invalidValue(
                path: "appearance.font_size",
                message: "Font size must be between 6 and 72"
            )
        }

        // Hand-copied from `DesignSystem.AwTextScale.range` (0.85...1.35): this
        // config layer can't depend on DesignSystem, so the bound is duplicated
        // deliberately. KEEP IN SYNC — change both together. Matching it means a
        // hand-edited TOML value that survives validation also survives the
        // scaling path without silent renormalization on first slider touch.
        guard (0.85...1.35).contains(uiTextScale) else {
            throw .invalidValue(
                path: "appearance.ui_text_scale",
                message: "UI text scale must be between 0.85 and 1.35"
            )
        }

        guard (0.0...1.0).contains(glowStrength) else {
            throw .invalidValue(
                path: "appearance.glow_strength",
                message: "Glow strength must be between 0.0 and 1.0"
            )
        }

        guard Self.normalizedTerminalBackgroundColor(terminalBackgroundColor) != nil else {
            throw .invalidValue(
                path: "appearance.terminal_background_color",
                message: "Terminal background color must be a #RRGGBB hex color"
            )
        }
    }

    public static func normalizedTerminalBackgroundColor(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.first == "#" else { return nil }
        let hex = String(trimmed.dropFirst())
        guard hex.count == 6, UInt32(hex, radix: 16) != nil else { return nil }
        return "#" + hex.lowercased()
    }
}
