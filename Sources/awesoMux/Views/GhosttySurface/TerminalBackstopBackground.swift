import AppKit
import AwesoMuxConfig

enum TerminalBackstopBackground {
    static func color(for hex: String) -> NSColor? {
        guard let normalized = AppearanceConfig.normalizedTerminalBackgroundColor(hex),
              let value = UInt32(String(normalized.dropFirst()), radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
