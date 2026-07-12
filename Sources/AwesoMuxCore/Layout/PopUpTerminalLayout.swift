import CoreGraphics

public enum PopUpTerminalLayout {
    public static let defaultExpandedSize = CGSize(width: 520, height: 360)
    public static let minimumExpandedSize = CGSize(width: 360, height: 240)
    public static let cornerTabSize = CGSize(width: 260, height: 48)
    public static let inset: CGFloat = 16
    public static let cornerRadius: CGFloat = 14

    public static func expandedSize(
        preferred: CGSize,
        availableFrame: CGRect,
        minimumSize: CGSize = minimumExpandedSize,
        bottomInset: CGFloat = inset
    ) -> CGSize {
        CGSize(
            width: max(minimumSize.width, min(preferred.width, availableFrame.width - inset * 2)),
            height: max(
                minimumSize.height,
                min(preferred.height, availableFrame.height - bottomInset - inset)
            )
        )
    }

    public static func origin(
        for size: CGSize,
        referenceFrame: CGRect,
        screenFrame: CGRect,
        bottomInset: CGFloat = inset
    ) -> CGPoint {
        let proposed = CGPoint(
            x: referenceFrame.maxX - size.width,
            y: referenceFrame.minY + bottomInset
        )
        let minX = screenFrame.minX + inset
        let maxX = max(minX, screenFrame.maxX - size.width)
        let minY = screenFrame.minY + bottomInset
        let maxY = max(minY, screenFrame.maxY - size.height - inset)
        return CGPoint(
            x: proposed.x.clamped(to: minX...maxX),
            y: proposed.y.clamped(to: minY...maxY)
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
