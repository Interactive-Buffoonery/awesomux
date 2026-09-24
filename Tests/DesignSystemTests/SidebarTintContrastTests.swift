import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("Sidebar tint contrast")
@MainActor
struct SidebarTintContrastTests {
    private let standardAppearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    private let allAppearances: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ]

    @Test("sidebar text clears WCAG AA")
    func sidebarTextClearsAA() throws {
        for appearance in standardAppearances {
            let text = try resolve(Color.aw.text, appearance: appearance)
            let tile = try resolve(Color.aw.surface.elevated, appearance: appearance)
            let hover = try composited(
                Color.aw.text,
                opacity: 0.06,
                over: Color.aw.surface.elevated,
                appearance: appearance
            )
            let railText = try resolve(Color.aw.railText, appearance: appearance)
            let sidebar = try resolve(Color.aw.surface.sidebar, appearance: appearance)

            expectContrast(text, tile, floor: 4.5, label: "tile text", appearance: appearance)
            expectContrast(text, hover, floor: 4.5, label: "hovered tile text", appearance: appearance)
            expectContrast(railText, sidebar, floor: 4.5, label: "rail text", appearance: appearance)
        }
    }

    @Test("standard appearance resolution ignores host Increase Contrast")
    func standardAppearanceResolutionIgnoresHostIncreaseContrast() throws {
        let color = Color(
            nsColor: NSColor.awDynamic(
                mocha: "#010101",
                latte: "#020202",
                mochaHC: "#030303",
                latteHC: "#040404"
            ))

        #expect(contrastRatio(try resolve(color, appearance: .aqua), NSColor.awHex("#020202")) == 1)
        #expect(contrastRatio(try resolve(color, appearance: .darkAqua), NSColor.awHex("#010101")) == 1)
    }

    @Test("workspace borders clear the non-text floor")
    func workspaceBordersClearNonTextFloor() throws {
        for appearance in standardAppearances {
            let tile = try resolve(Color.aw.surface.elevated, appearance: appearance)
            let sidebar = try resolve(Color.aw.surface.sidebar, appearance: appearance)

            for accent in AwTintAccent.allCases {
                let border = try resolve(Color.aw.tintBorder(accent), appearance: appearance)
                expectContrast(
                    border,
                    tile,
                    floor: 3,
                    label: "\(accent) active border on tile",
                    appearance: appearance
                )
                expectContrast(
                    border,
                    sidebar,
                    floor: 3,
                    label: "\(accent) active border on sidebar",
                    appearance: appearance
                )
            }
        }
    }

    @Test("increased-contrast tile borders clear the non-text floor")
    func increasedContrastBordersClearNonTextFloor() throws {
        for appearance in [
            NSAppearance.Name.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ] {
            let tile = try resolve(Color.aw.surface.elevated, appearance: appearance)
            let hover = try composited(
                Color.aw.text,
                opacity: 0.06,
                over: Color.aw.surface.elevated,
                appearance: appearance
            )
            let sidebar = try resolve(Color.aw.surface.sidebar, appearance: appearance)
            let active = try resolve(Color.aw.dividerHoverHC, appearance: appearance)
            let resting = try resolve(Color.aw.dividerRestHC, appearance: appearance)
            let needs = try resolve(Color.aw.status.needs, appearance: appearance)

            for (label, foreground, background) in [
                ("active border on tile", active, tile),
                ("active border on sidebar", active, sidebar),
                ("resting border on tile", resting, tile),
                ("resting border on sidebar", resting, sidebar),
                ("hovered resting border", active, hover),
                ("needs border on tile", needs.withAlphaComponent(0.95).composited(over: tile), tile),
                ("needs border on hover", needs.withAlphaComponent(0.95).composited(over: hover), hover),
                ("needs border on sidebar", needs.withAlphaComponent(0.95).composited(over: sidebar), sidebar),
            ] {
                expectContrast(
                    foreground,
                    background,
                    floor: 3,
                    label: label,
                    appearance: appearance
                )
            }
        }
    }

    @Test("sidebar status indicators clear the non-text floor")
    func statusIndicatorsClearNonTextFloor() throws {
        let indicators: [(String, Color)] = [
            ("needs", Color.aw.status.needs),
            ("error", Color.aw.status.error),
            ("thinking", Color.aw.status.thinking),
            ("output", Color.aw.status.output),
        ]

        for appearance in allAppearances {
            let tile = try resolve(Color.aw.surface.elevated, appearance: appearance)
            let hover = try composited(
                Color.aw.text,
                opacity: 0.06,
                over: Color.aw.surface.elevated,
                appearance: appearance
            )
            let sidebar = try resolve(Color.aw.surface.sidebar, appearance: appearance)

            for (name, color) in indicators {
                let indicator = try resolve(color, appearance: appearance)
                expectContrast(
                    indicator,
                    sidebar,
                    floor: 3,
                    label: "\(name) indicator on sidebar",
                    appearance: appearance
                )
            }

            let needs = try resolve(Color.aw.status.needs, appearance: appearance)
            let floatingWork = try resolve(Color.aw.status.floatingWork, appearance: appearance)
            expectContrast(needs, tile, floor: 3, label: "needs indicator on tile", appearance: appearance)
            expectContrast(needs, hover, floor: 3, label: "needs indicator on hover", appearance: appearance)
            expectContrast(
                floatingWork,
                tile,
                floor: 3,
                label: "floating-work indicator on tile",
                appearance: appearance
            )
        }
    }

    @Test("sidebar views keep the contrast-safe tokens wired")
    func sidebarViewsKeepContrastSafeTokensWired() throws {
        let contracts: [(String, [String])] = [
            (
                "Sources/awesoMux/Views/SidebarSessionTile.swift",
                [
                    "Color.aw.status.floatingWork",
                    "Color.aw.railText",
                    "isHovered ? Color.aw.dividerHoverHC : Color.aw.dividerRestHC",
                    "isHighContrast && !tintedHighContrast ? Color.aw.dividerHoverHC : tint.borderHue",
                ]
            ),
            ("Sources/awesoMux/Views/SidebarGroupHeaderView.swift", ["Color.aw.railText"]),
            ("Sources/awesoMux/Views/SidebarPinnedSectionView.swift", ["Color.aw.railText"]),
        ]

        for (path, requiredText) in contracts {
            let source = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            for text in requiredText {
                #expect(source.contains(text), "\(path) must contain `\(text)`")
            }
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func resolve(_ color: Color, appearance: NSAppearance.Name) throws -> NSColor {
        let dynamicColor = NSColor(color)
        let prefix = "awDynamic-"
        let name = dynamicColor.colorNameComponent
        guard name.hasPrefix(prefix) else {
            Issue.record("Expected an awDynamic color, got `\(name)`")
            return try #require(dynamicColor.usingColorSpace(.sRGB))
        }

        let components = name.dropFirst(prefix.count).split(separator: "-").map(String.init)
        guard components.count == 4 else {
            Issue.record("Malformed awDynamic color name `\(name)`")
            return try #require(dynamicColor.usingColorSpace(.sRGB))
        }

        return NSColor.awHex(
            NSColor.awDynamicHex(
                for: appearance,
                mocha: components[0],
                latte: components[1],
                mochaHC: components[2],
                latteHC: components[3]
            ))
    }

    private func composited(
        _ overlay: Color,
        opacity: CGFloat,
        over background: Color,
        appearance: NSAppearance.Name
    ) throws -> NSColor {
        let foreground = try resolve(overlay, appearance: appearance).withAlphaComponent(opacity)
        let background = try resolve(background, appearance: appearance)
        return foreground.composited(over: background)
    }

    private func expectContrast(
        _ foreground: NSColor,
        _ background: NSColor,
        floor: Double,
        label: String,
        appearance: NSAppearance.Name
    ) {
        let ratio = contrastRatio(foreground, background)
        #expect(ratio >= floor, "\(label) in \(appearance.rawValue): \(ratio):1 < \(floor):1")
    }
}

private func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    return (max(firstLuminance, secondLuminance) + 0.05)
        / (min(firstLuminance, secondLuminance) + 0.05)
}

private func relativeLuminance(_ color: NSColor) -> Double {
    let color = color.usingColorSpace(.sRGB) ?? color
    func linearize(_ channel: CGFloat) -> Double {
        let value = Double(channel)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(color.redComponent)
        + 0.7152 * linearize(color.greenComponent)
        + 0.0722 * linearize(color.blueComponent)
}

private extension NSColor {
    func composited(over background: NSColor) -> NSColor {
        guard alphaComponent < 1 else { return self }
        let alpha = alphaComponent
        return NSColor(
            red: redComponent * alpha + background.redComponent * (1 - alpha),
            green: greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }
}
