import CoreGraphics

enum AppTitlebarMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let contentColumnGutter: CGFloat = 16
    static let lockupPadding: CGFloat = 10
    static let brandWithTextMinimumWidth = brandWithTextMinimumWidth(leadingInset: trafficLightClearance)

    static func brandWithTextMinimumWidth(leadingInset: CGFloat) -> CGFloat {
        leadingInset + 94
    }

    static func brandIconMinimumWidth(leadingInset: CGFloat) -> CGFloat {
        leadingInset + 28
    }

    static let panelTitlebarHeight: CGFloat = 32
    /// Keeps the legacy compact band with a small bottom-only cushion below
    /// the native controls.
    static let layoutHeight: CGFloat = 44

    /// Initial room while a view is unattached. Live bands use AppKit's
    /// measured controls rather than assuming a toolbar style has this height.
    static let fallbackHeight: CGFloat = 52
}
