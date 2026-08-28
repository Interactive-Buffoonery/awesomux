import Foundation

enum PaneTitleBarStrings {
    static let rename = String(
        localized: "Rename…",
        comment: "Pane title-bar context-menu and VoiceOver action for renaming a pane."
    )
    static let resetToTerminalTitle = String(
        localized: "Reset to Terminal Title",
        comment: "Pane title-bar context-menu and VoiceOver action that restores the terminal title."
    )
    static let moveToNewWorkspace = String(
        localized: "Move Pane to New Workspace",
        comment: "Pane title-bar context-menu and VoiceOver action that moves a pane into its own workspace."
    )
    static let color = String(
        localized: "Color…",
        comment: "Pane title-bar context-menu submenu for choosing a pane color."
    )
    static let defaultColor = String(
        localized: "Default",
        comment: "Pane title-bar color submenu item that clears a custom pane color."
    )
}
