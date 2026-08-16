import DesignSystem
import SwiftUI

/// Title bar band for the window-family floating panels.
///
/// These panels host real traffic lights (ADR-0032). Without a band, each
/// header has to reserve leading space to step around them, which reads as
/// stray indentation rather than layout. The band owns the row instead, so
/// content below it starts at the panel's own padding again.
///
/// Settings established this shape first (`SettingsShell.titlebar`), and this
/// borrows its look without the brand zone: the wordmark identifies the app in
/// Settings and the main window, and repeating it on an auxiliary panel would
/// claim more than the panel is.
///
/// The gradient and hairline below are a small deliberate copy of Settings'
/// rather than a shared primitive — two consumers do not need one. They are not
/// contractually bound to stay identical; if these surfaces are ever meant to
/// move together, extract the modifier at that point rather than assuming it.
///
/// ponytail: no `WindowDragGesture` here, unlike Settings. These panels are
/// summoned at a fixed anchor and dismiss on resign-key, so dragging one is a
/// rare gesture, and `isMovableByWindowBackground` is deliberately false on
/// them. Add the gesture to this band if panels ever become movable.
struct FloatingPanelTitlebar: View {
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .awFont(AwFont.Mono.meta)
                // Not `text3`: it lands at 2.42:1 on this gradient in Latte.
                // `titlebarText` keeps that quiet weight everywhere it already
                // cleared AA and steps only Latte down.
                .foregroundStyle(Color.aw.titlebarText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppTitlebarMetrics.trafficLightClearance)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity)
        // `panelTitlebarHeight`, not `AwSpacing.titlebar` — see the metric's own
        // note. Matching the native title bar is what puts this title on the
        // traffic lights' centre line instead of 3pt under it.
        .frame(height: AppTitlebarMetrics.panelTitlebarHeight)
        .background {
            LinearGradient(
                colors: [Color.aw.surface.chrome2, Color.aw.surface.chrome],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
        // A heading, not decoration. Settings sets the same trait on the band
        // element that carries its identity and hides only the second, echoing
        // label (`SettingsShell.swift:119` and `:139`). Hiding this one too
        // would leave the cheatsheet with no heading at all until a search
        // matched something, so its Headings rotor would be empty on open.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}
