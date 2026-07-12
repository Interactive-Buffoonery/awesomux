import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct SettingsFontPickerMenu: View {
    @Binding var selection: String
    let fieldLabel: String
    let systemValue: String
    let systemLabel: String
    let fonts: [SettingsFontFamily]

    var body: some View {
        Menu {
            Button(systemLabel) { selection = systemValue }
            if !fonts.isEmpty {
                Divider()
                ForEach(fonts) { family in
                    Button(family.displayName) { selection = family.name }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .fill(Color.aw.surface.elevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .stroke(Color.aw.border, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(currentLabel)
        .accessibilityLabel(fieldLabel)
        .accessibilityValue(currentLabel)
    }

    private var currentLabel: String {
        if selection == systemValue {
            return systemLabel
        }
        // Case-insensitive: font APIs resolve family names case-insensitively,
        // so a hand-edited selection that differs only in case is installed and
        // must not be labeled "(missing)".
        if let match = fonts.first(where: { $0.name.caseInsensitiveCompare(selection) == .orderedSame }) {
            if match.name == TerminalAppearancePreferences.bundledMonoFont {
                return String(
                    localized: "\(match.displayName) (Bundled)",
                    comment: "Font picker label suffix for the font family shipped inside the app bundle"
                )
            }
            return match.displayName
        }
        // Selection persisted on disk but the family isn't currently
        // installed/registered — tell the user, don't lie about it.
        return String(
            localized: "\(selection) (missing)",
            comment: "Font picker label suffix when the saved font family is not installed"
        )
    }
}

struct SettingsFontFamily: Identifiable, Hashable {
    let name: String
    let displayName: String

    var id: String { name }

    /// Enumerates installed font families and filters by monospace
    /// trait. Results are cached process-wide because the underlying
    /// `NSFontManager` lookup is expensive — it instantiates a concrete
    /// font for every family on the system (200–800 fonts on a
    /// typical dev machine) just to read its descriptor traits. Without
    /// caching, switching from Appearance → Terminal → Appearance in
    /// the Settings sidebar triggered three full enumerations.
    @MainActor
    static func installed(monospaced: Bool) -> [SettingsFontFamily] {
        if monospaced, let cached = SettingsFontCatalog.cachedMonospace { return cached }
        if !monospaced, let cached = SettingsFontCatalog.cachedProportional { return cached }

        let manager = NSFontManager.shared
        let availableNames = manager.availableFontFamilies

        let filtered: [String] = availableNames.compactMap { family in
            guard !family.hasPrefix(".") else { return nil }
            // `NSFont(name:size:)` expects a PostScript name and returns nil
            // for family names, so resolve the family through NSFontManager
            // to get a concrete font whose descriptor carries the traits.
            guard let font = manager.font(
                withFamily: family,
                traits: [],
                weight: 5,
                size: 13
            ) else { return nil }

            let traits = font.fontDescriptor.symbolicTraits
            let isMono = traits.contains(.monoSpace)
            return (isMono == monospaced) ? family : nil
        }

        let result = filtered.sorted().map {
            SettingsFontFamily(name: $0, displayName: $0)
        }
        let families = monospaced
            ? Self.includingBundledMonoFont(in: result)
            : Self.includingBundledUIFont(in: result)
        if monospaced {
            SettingsFontCatalog.cachedMonospace = families
        } else {
            SettingsFontCatalog.cachedProportional = families
        }
        return families
    }

    /// Case-insensitive index of installed *proportional* families: lowercased
    /// name → the catalog's own spelling. Backs the `appearance.ui_font` probe
    /// in `AppearanceBridge`; cached like the catalogs above so bridge body
    /// evaluations cost a dictionary hit, not an NSFontManager enumeration.
    /// Proportional-only on purpose: the Interface font picker only offers
    /// proportional families, so a hand-edited monospace `ui_font` gets the
    /// same treatment as an uninstalled one (system fallback).
    @MainActor
    static func proportionalFamilyIndex() -> [String: String] {
        if let cached = SettingsFontCatalog.cachedProportionalIndex { return cached }
        let index = Dictionary(
            installed(monospaced: false).map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        SettingsFontCatalog.cachedProportionalIndex = index
        return index
    }

    private static func includingBundledMonoFont(
        in families: [SettingsFontFamily]
    ) -> [SettingsFontFamily] {
        let bundledName = TerminalAppearancePreferences.bundledMonoFont
        // Only surface the bundled family if CoreText actually saw it from
        // the app bundle's `ATSApplicationFontsPath`. Listing it when
        // registration failed (alternate launch path, packaging drift)
        // would let the user pick a font that libghostty can't resolve.
        guard families.contains(where: { $0.name == bundledName }) else {
            return families
        }
        let remaining = families.filter { $0.name != bundledName }
        return [
            SettingsFontFamily(name: bundledName, displayName: bundledName)
        ] + remaining
    }

    private static func includingBundledUIFont(
        in families: [SettingsFontFamily]
    ) -> [SettingsFontFamily] {
        let bundledName = DesignSystemFonts.geistFamilyName
        guard let geist = families.first(where: {
            $0.name.caseInsensitiveCompare(bundledName) == .orderedSame
        }) else {
            return families
        }
        let remaining = families.filter {
            $0.name.caseInsensitiveCompare(bundledName) != .orderedSame
        }
        return [geist] + remaining
    }
}

@MainActor
enum SettingsFontCatalog {
    static var cachedMonospace: [SettingsFontFamily]?
    static var cachedProportional: [SettingsFontFamily]?
    static var cachedProportionalIndex: [String: String]?
}
