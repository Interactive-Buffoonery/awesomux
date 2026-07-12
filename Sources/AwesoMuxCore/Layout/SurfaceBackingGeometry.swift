import CoreGraphics

/// Backing-pixel geometry derived from a point-space size and backing scale.
///
/// libghostty's `ghostty_surface_set_size` takes backing pixels (width/height
/// in physical pixels) and `ghostty_surface_set_content_scale` takes the
/// scale factor. This type holds both together so consumers can use a single
/// `==` to decide whether the surface needs a fresh `set_size` + `set_content_scale`
/// pass — and tests can pin the conversion logic without standing up an
/// NSView host.
///
/// Why: AppKit's `convertToBacking(_:)` produces an `NSSize` that's just
/// `pointSize × backingScaleFactor`, but the conversion to `UInt32` floors
/// at 1 to keep libghostty happy on transient zero-sized layouts. That
/// flooring is the testable invariant.
public struct SurfaceBackingGeometry: Equatable, Sendable {
    public let scale: CGFloat
    public let width: UInt32
    public let height: UInt32

    public init(pointSize: CGSize, backingScale: CGFloat) {
        let backingWidth = pointSize.width * backingScale
        let backingHeight = pointSize.height * backingScale
        self.scale = backingScale
        self.width = UInt32(max(1, backingWidth))
        self.height = UInt32(max(1, backingHeight))
    }
}
