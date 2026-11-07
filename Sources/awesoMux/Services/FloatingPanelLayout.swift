import AppKit

struct FloatingPanelLayout {
    static let commandPalette = Self(defaultSize: CGSize(width: 620, height: 430))
    static let keyboardCheatsheet = Self(defaultSize: CGSize(width: 860, height: 630))
    let defaultSize: CGSize
    private let inset: CGFloat = 16

    /// Clamp the default panel size to the visible frame (minus insets) so the
    /// panel stays fully on-screen on small displays, Split View, or Stage
    /// Manager. Returns `defaultSize` unchanged when there's room.
    func resolvedSize(
        screenFrame: CGRect?
    ) -> CGSize {
        guard let screenFrame else { return defaultSize }
        let maxWidth = max(0, screenFrame.width - inset * 2)
        let maxHeight = max(0, screenFrame.height - inset * 2)
        return CGSize(
            width: min(defaultSize.width, maxWidth),
            height: min(defaultSize.height, maxHeight)
        )
    }

    func origin(
        panelSize: CGSize,
        referenceFrame: CGRect?,
        screenFrame: CGRect?
    ) -> CGPoint? {
        guard let screenFrame else { return nil }
        let reference = referenceFrame ?? screenFrame
        let unclamped = CGPoint(
            x: reference.midX - panelSize.width / 2,
            y: reference.midY - panelSize.height / 2
        )
        return clampOrigin(unclamped, panelSize: panelSize, screenFrame: screenFrame)
    }

    /// Clamp an already-known origin (e.g. a remembered drag position) back into
    /// the visible frame so a remembered spot on a now-disconnected display
    /// doesn't open the palette offscreen.
    func clampOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        screenFrame: CGRect?
    ) -> CGPoint {
        guard let screenFrame else { return origin }
        let minX = screenFrame.minX + inset
        let maxX = max(minX, screenFrame.maxX - panelSize.width - inset)
        let minY = screenFrame.minY + inset
        let maxY = max(minY, screenFrame.maxY - panelSize.height - inset)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}
