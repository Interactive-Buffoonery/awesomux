import AppKit

extension NSView {
    /// `aw`-prefixed: a bare `firstSubview(of:)` on NSView invites collisions
    /// with future extensions of the same generic name.
    func awFirstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.awFirstSubview(of: type) {
                return match
            }
        }

        return nil
    }
}
