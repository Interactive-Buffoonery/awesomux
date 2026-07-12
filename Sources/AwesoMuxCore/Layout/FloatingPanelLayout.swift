import CoreGraphics

public enum FloatingPanelLayout {
    public static let defaultSize = CGSize(width: 640, height: 480)
    /// Floating panels become user-resizable in the unified controller; this
    /// is the resize floor and the size-store validity floor.
    public static let minimumSize = CGSize(width: 480, height: 360)
    /// Shared by the SwiftUI chrome (clip + strokes) and the AppKit
    /// content-layer mask — the two must agree or a hairline of content
    /// peeks past the stroke at the corners.
    public static let cornerRadius: CGFloat = 14
    public static let minimumScreenInset: CGFloat = 40

    public static func origin(
        panelSize: CGSize,
        referenceFrame: CGRect?,
        screenFrame: CGRect?,
        minimumScreenInset: CGFloat = Self.minimumScreenInset
    ) -> CGPoint? {
        guard let referenceFrame, let screenFrame else {
            return nil
        }

        // Center the panel over the parent window on both axes. (It used to
        // ride a fixed offset down from the top edge, which bled into the tab
        // chrome on shorter windows.)
        let proposedX = referenceFrame.midX - panelSize.width / 2
        let proposedY = referenceFrame.midY - panelSize.height / 2
        let minX = screenFrame.minX + minimumScreenInset
        let maxX = screenFrame.maxX - panelSize.width - minimumScreenInset
        let minY = screenFrame.minY + minimumScreenInset
        let maxY = screenFrame.maxY - panelSize.height - minimumScreenInset

        return CGPoint(
            x: proposedX.clamped(to: minX...max(minX, maxX)),
            y: proposedY.clamped(to: minY...max(minY, maxY))
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
