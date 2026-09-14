import CoreGraphics

enum AppTitlebarMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let contentColumnGutter: CGFloat = 16
    static let lockupPadding: CGFloat = 10
    static let brandWithTextMinimumWidth = trafficLightClearance + 94

    static let panelTitlebarHeight: CGFloat = 32

    /// Initial room while a view is unattached. Live bands use AppKit's
    /// measured controls rather than assuming a toolbar style has this height.
    static let fallbackHeight: CGFloat = 52
}
