import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct UpdateAvailableIndicator: View {
    let displayMode: SidebarWidthMode

    @Environment(UpdateController.self) private var updateController
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        if let version = updateController.availableVersion {
            indicator(for: version)
        }
    }

    private func indicator(for version: String) -> some View {
        let accessibilityLabel = Self.accessibilityLabel(for: version)
        return AppDropdown(
            items: [
                AppDropdownItem(title: String(localized: "Update…")) { updateController.checkForUpdates() },
                AppDropdownItem(title: String(localized: "Skip for Now")) { updateController.skipAvailableUpdate() },
            ], menuTitle: accessibilityLabel
        ) {
            label
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(String(localized: "Opens update options"))
        .help(accessibilityLabel)
            .frame(
                width: displayMode == .collapsed ? 40 : nil,
                height: displayMode == .collapsed ? 40 : nil
            )
            .frame(
                minHeight: displayMode == .collapsed ? nil : 32
            )
            .frame(maxWidth: displayMode == .collapsed ? .infinity : nil, alignment: .center)
            .padding(.horizontal, displayMode == .collapsed ? 10 : 12)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var label: some View {
        if displayMode == .collapsed {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .foregroundStyle(Self.foregroundColor(for: displayMode, accent: accentResolver.accent))
                .background(
                    Self.backgroundColor(for: displayMode, accent: accentResolver.accent),
                    in: RoundedRectangle(cornerRadius: AwRadius.panel)
                )
        } else {
            Label(
                String(localized: "Update Available", comment: "Sidebar update reminder title"),
                systemImage: "arrow.down.circle"
            )
            .awFont(AwFont.Mono.meta)
            .foregroundStyle(Self.foregroundColor(for: displayMode, accent: accentResolver.accent))
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .background(
                Self.backgroundColor(for: displayMode, accent: accentResolver.accent),
                in: RoundedRectangle(cornerRadius: AwRadius.pill)
            )
        }
    }

    static func accessibilityLabel(for version: String) -> String {
        String(
            localized: "Update available, version \(version)",
            comment: "Accessibility label for the sidebar update reminder; placeholder is the available version"
        )
    }

    static func foregroundColor(for displayMode: SidebarWidthMode, accent: AwAccent) -> Color {
        displayMode == .collapsed ? Color.aw.accentOnChrome(accent) : Color.aw.text
    }

    static func backgroundColor(for displayMode: SidebarWidthMode, accent: AwAccent) -> Color {
        displayMode == .collapsed
            ? Color.aw.surface.elevated.opacity(0.6)
            : Color.aw.accentSoft(accent)
    }
}
