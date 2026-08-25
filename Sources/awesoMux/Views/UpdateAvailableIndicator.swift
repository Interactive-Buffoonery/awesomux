import AwesoMuxCore
import DesignSystem
import SwiftUI

struct UpdateAvailableIndicator: View {
    let displayMode: SidebarWidthMode

    @Environment(UpdateController.self) private var updateController

    var body: some View {
        if let content = UpdateAvailableIndicatorContent(
            availableVersion: updateController.availableVersion,
            displayMode: displayMode
        ) {
            Menu {
                ForEach(content.actions) { action in
                    Button(action.title) {
                        action.perform(using: updateController)
                    }
                }
            } label: {
                label(content: content)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Color.aw.accent)
            .accessibilityLabel(content.accessibilityLabel)
            .accessibilityValue(content.version)
            .accessibilityHint(
                String(
                    localized: "Opens update options",
                    comment: "Accessibility hint for the available update sidebar indicator"
                )
            )
            .help(content.accessibilityLabel)
        }
    }

    @ViewBuilder
    private func label(content: UpdateAvailableIndicatorContent) -> some View {
        if content.usesCollapsedPresentation {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .foregroundStyle(Color.aw.accent)
                .background(
                    Color.aw.surface.elevated.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: AwRadius.panel)
                )
        } else {
            Label(content.title, systemImage: "arrow.down.circle")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.accentOnChrome)
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
                .background(
                    Color.aw.accentSoft,
                    in: RoundedRectangle(cornerRadius: AwRadius.pill)
                )
        }
    }
}

struct UpdateAvailableIndicatorContent: Equatable {
    let version: String
    let displayMode: SidebarWidthMode

    init?(availableVersion: String?, displayMode: SidebarWidthMode) {
        guard let availableVersion else {
            return nil
        }
        version = availableVersion
        self.displayMode = displayMode
    }

    var title: String {
        String(localized: "Update Available", comment: "Sidebar update reminder title")
    }

    var accessibilityLabel: String {
        String(
            localized: "Update available, version \(version)",
            comment: "Accessibility label for the sidebar update reminder; placeholder is the available version"
        )
    }

    var actions: [UpdateAvailableIndicatorAction] { [.update, .skipForNow] }
    var usesCollapsedPresentation: Bool { displayMode == .collapsed }
}

enum UpdateAvailableIndicatorAction: CaseIterable, Identifiable {
    case update
    case skipForNow

    var id: Self { self }

    var title: String {
        switch self {
        case .update:
            String(localized: "Update…", comment: "Action that starts the standard update flow")
        case .skipForNow:
            String(localized: "Skip for Now", comment: "Action that hides the current sidebar update reminder")
        }
    }

    @MainActor
    func perform(using controller: UpdateController) {
        switch self {
        case .update:
            controller.checkForUpdates()
        case .skipForNow:
            controller.skipAvailableUpdate()
        }
    }
}
