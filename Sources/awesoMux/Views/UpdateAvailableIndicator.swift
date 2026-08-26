import AwesoMuxCore
import DesignSystem
import SwiftUI

struct UpdateAvailableIndicator: View {
    let displayMode: SidebarWidthMode

    @Environment(UpdateController.self) private var updateController
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        if let version = updateController.availableVersion {
            Menu {
                Button(
                    String(
                        localized: "Update…",
                        comment: "Action that starts the standard update flow"
                    )
                ) {
                    updateController.checkForUpdates()
                }
                Button(
                    String(
                        localized: "Skip for Now",
                        comment: "Action that hides the current sidebar update reminder"
                    )
                ) {
                    updateController.skipAvailableUpdate()
                }
            } label: {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(for: version))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .tint(Color.aw.accent(accentResolver.accent))
            .frame(
                width: displayMode == .collapsed ? 40 : nil,
                height: displayMode == .collapsed ? 40 : nil
            )
            .frame(
                minHeight: displayMode == .collapsed ? nil : 32
            )
            .accessibilityHint(
                String(
                    localized: "Opens update options",
                    comment: "Accessibility hint for the available update sidebar indicator"
                )
            )
            .help(Self.accessibilityLabel(for: version))
            .padding(.horizontal, displayMode == .collapsed ? 10 : 12)
            .padding(.vertical, 6)
        }
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
