import Foundation

public struct TerminalThemeCatalog: Sendable {
    public static let catppuccinID = "catppuccin"
    public static let selenizedID = "selenized"
    public static let builtIn = TerminalThemeCatalog()

    private let providers: [String: any TerminalThemeProvider]

    public init(providers customProviders: [String: any TerminalThemeProvider] = [:]) {
        var providers: [String: any TerminalThemeProvider] = [
            Self.catppuccinID: CatppuccinThemeProvider(),
            Self.selenizedID: SelenizedThemeProvider(),
        ]
        for (id, provider) in customProviders {
            providers[Self.normalizedID(id)] = provider
        }
        self.providers = providers
    }

    public func provider(matching id: String) -> (any TerminalThemeProvider)? {
        providers[Self.normalizedID(id)]
    }

    public func provider(for id: String?) -> any TerminalThemeProvider {
        guard let id,
            let provider = provider(matching: id)
        else {
            return providers[Self.catppuccinID] ?? CatppuccinThemeProvider()
        }
        return provider
    }

    func ghosttyColorConfigLines(
        for id: String?,
        theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> [String] {
        let provider = provider(for: id)
        if let catppuccin = provider as? CatppuccinThemeProvider {
            return catppuccin.ghosttyColorConfigLines(for: theme)
        }

        var lines = provider.ansi16(for: theme).enumerated().map { index, hex in
            "palette = \(index)=\(hex)"
        }
        lines.append("foreground = \(provider.foreground(for: theme))")
        return lines
    }

    private static func normalizedID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
