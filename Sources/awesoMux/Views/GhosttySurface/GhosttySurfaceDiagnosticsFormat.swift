import CoreGraphics
import Foundation

enum GhosttySurfaceDiagnosticsFormat {
    static func sizeDescription(_ size: CGSize) -> String {
        "\(coordinateDescription(size.width))x\(coordinateDescription(size.height))"
    }

    static func coordinateDescription(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
