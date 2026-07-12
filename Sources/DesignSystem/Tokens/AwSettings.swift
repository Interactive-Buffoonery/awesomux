import SwiftUI

/// Geometry tokens specific to the Settings shell. These values come from
/// the shipped settings surfaces and do
/// not fit naturally into the existing `AwSpacing` / `AwRadius` enums
/// because they only describe one surface.
public enum AwSettings {
    /// Width of the Settings sidebar column. Matches handoff layout.
    public static let sidebarWidth: CGFloat = 188

    /// Fixed width of the label column inside a `SettingsField` row.
    /// The control column fills the remainder.
    public static let fieldLabelWidth: CGFloat = 200

    /// Vertical padding inside a `SettingsField` row. The hairline divider
    /// is drawn at the top of each row inside this padding.
    public static let fieldVerticalPadding: CGFloat = 16

    /// Insets applied to the detail/content column of the Settings shell.
    ///
    /// `SettingsShell` draws an in-content title bar under the hidden native
    /// title bar, so this top inset is the deliberate gap below that band. Kept tight so the first section
    /// sits a comfortable distance under the band rather than floating in a void.
    /// The sidebar column reuses this top value so both columns share one
    /// baseline directly beneath the band.
    public static let contentInset = EdgeInsets(
        top: 18,
        leading: 36,
        bottom: 28,
        trailing: 36
    )

    /// Preferred launch size for the Settings window. The view still compresses
    /// below this so the window can fit smaller displays without clipping.
    public static let preferredWindowSize = CGSize(width: 1120, height: 720)

    /// Width of the quick-settings sheet attached to the main window.
    public static let quickSheetWidth: CGFloat = 360
}
