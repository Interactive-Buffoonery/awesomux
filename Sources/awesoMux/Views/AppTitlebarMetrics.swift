import CoreGraphics

enum AppTitlebarMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let contentColumnGutter: CGFloat = 16
    static let lockupPadding: CGFloat = 10
    static let brandWithTextMinimumWidth = trafficLightClearance + 94

    /// Height of the native title bar on a floating panel that carries no
    /// toolbar — measured, not chosen: AppKit lays the traffic lights out at
    /// y=9 with a 14pt height inside a 32pt container, putting their centre
    /// exactly 16pt from the window top.
    ///
    /// Deliberately NOT `AwSpacing.titlebar` (38). That taller value belongs to
    /// the main window and Settings, which set `toolbarStyle = .unifiedCompact`
    /// and get a correspondingly taller native title bar. A band drawn at 38 on
    /// a toolbar-less panel centres its title at 19pt, 3pt below the lights —
    /// close enough to look like sloppy baseline alignment rather than a
    /// geometry mismatch. `FloatingPanelTitlebarGeometryTests` locks this
    /// against the real AppKit layout.
    static let panelTitlebarHeight: CGFloat = 32
}
