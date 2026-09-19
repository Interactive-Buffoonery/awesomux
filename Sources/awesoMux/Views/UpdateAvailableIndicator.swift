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
        return
            label
            .accessibilityHidden(true)
            .overlay(
                UpdateAvailableMenuButton(
                    title: displayMode == .collapsed
                        ? ""
                        : String(
                            localized: "Update Available",
                            comment: "Sidebar update reminder title"
                        ),
                    accessibilityLabel: accessibilityLabel,
                    accessibilityHint: String(
                        localized: "Opens update options",
                        comment: "Accessibility hint for the available update sidebar indicator"
                    ),
                    onCheckForUpdates: { updateController.checkForUpdates() },
                    onSkipAvailableUpdate: { updateController.skipAvailableUpdate() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
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

/// Click target for the indicator. The SwiftUI label underneath draws the
/// visuals; this AppKit button owns the menu and, importantly, the
/// accessibility element.
///
/// A SwiftUI `Menu` renders an AppKit `SwiftUIPopupButton`, and SwiftUI's
/// `.accessibilityLabel` never reaches it — the control exposes only its
/// visible text. Owning the control keeps the version-bearing label on the
/// element VoiceOver actually reads.
@MainActor
private struct UpdateAvailableMenuButton: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let onCheckForUpdates: () -> Void
    let onSkipAvailableUpdate: () -> Void

    func makeNSView(context: Context) -> UpdateAvailableMenuNSButton {
        let button = UpdateAvailableMenuNSButton()
        update(button)
        return button
    }

    func updateNSView(_ nsView: UpdateAvailableMenuNSButton, context: Context) {
        update(nsView)
    }

    private func update(_ button: UpdateAvailableMenuNSButton) {
        button.title = title
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHint)
        button.toolTip = accessibilityLabel
        button.onCheckForUpdates = onCheckForUpdates
        button.onSkipAvailableUpdate = onSkipAvailableUpdate
    }
}

@MainActor
final class UpdateAvailableMenuNSButton: NSButton {
    var onCheckForUpdates: (() -> Void)?
    var onSkipAvailableUpdate: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        isTransparent = true
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(presentMenu)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The SwiftUI label underneath draws the indicator; this proxy only owns
    /// the menu and the accessibility element.
    override func draw(_ dirtyRect: NSRect) {}

    override func accessibilityPerformPress() -> Bool {
        presentMenu()
        return true
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let updateItem = NSMenuItem(
            title: String(
                localized: "Update…",
                comment: "Action that starts the standard update flow"
            ),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        let skipItem = NSMenuItem(
            title: String(
                localized: "Skip for Now",
                comment: "Action that hides the current sidebar update reminder"
            ),
            action: #selector(skipAvailableUpdate),
            keyEquivalent: ""
        )
        skipItem.target = self
        menu.addItem(skipItem)
        return menu
    }

    @objc private func presentMenu() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func skipAvailableUpdate() {
        onSkipAvailableUpdate?()
    }
}
