import AwesoMuxCore
import CoreGraphics

/// Configuration that distinguishes the two terminal-panel invocation modes.
/// The companion invocation adds minimize-to-corner-tab and cross-workspace
/// persistence; everything else is the same panel. Differences are expressed
/// as data here rather than subclasses of the controller.
struct TerminalPanelMode: Equatable {
    enum Anchor: Equatable {
        /// Companion: lower-right card pinned above the workspace footer.
        case bottomTrailing
        /// Floating: centered over the parent window.
        case center
    }

    var anchor: Anchor
    /// ADR-0030: floating keeps bare Escape as smart-dismiss; companion delivers
    /// Escape to the terminal (TUIs need it) and never intercepts it.
    var interceptsBareEscape: Bool
    var hasCornerTab: Bool
    /// Companion owns one app-wide store that survives workspace changes;
    /// floating keeps one temporary slot per workspace.
    var persistsAcrossWorkspaces: Bool
    var sizeStoreKey: String
    var minimumSize: CGSize
    var defaultSize: CGSize
    /// Window title / accessibility label. Companion is localized; floating
    /// preserves the pre-unification literal treatment (see deleted
    /// FloatingPanelController).
    var windowTitle: String

    static let companion = TerminalPanelMode(
        anchor: .bottomTrailing,
        interceptsBareEscape: false,
        hasCornerTab: true,
        persistsAcrossWorkspaces: true,
        sizeStoreKey: "com.awesomux.terminalCompanion.size",
        minimumSize: PopUpTerminalLayout.minimumExpandedSize,
        defaultSize: PopUpTerminalLayout.defaultExpandedSize,
        windowTitle: String(
            localized: "Terminal Companion",
            comment: "Window title and accessibility label for the Terminal Companion."
        )
    )

    static let floating = TerminalPanelMode(
        anchor: .center,
        interceptsBareEscape: true,
        hasCornerTab: false,
        persistsAcrossWorkspaces: false,
        sizeStoreKey: "com.awesomux.floatingPanel.size",
        minimumSize: FloatingPanelLayout.minimumSize,
        defaultSize: FloatingPanelLayout.defaultSize,
        windowTitle: "Floating Panel"
    )
}
