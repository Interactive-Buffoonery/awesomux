import DesignSystem
import SwiftUI

struct Brandmark: View {
    let size: CGFloat
    let showsText: Bool
    @Environment(\.awAccent) private var accentResolver

    init(size: CGFloat = 14, showsText: Bool = true) {
        self.size = size
        self.showsText = showsText
    }

    var body: some View {
        let accent = accentResolver.accent
        let accentColor = Color.aw.accent(accent)
        let accentGlow = Color.aw.accentGlow(accent)
        let wordmarkColor = Color.aw.accentOnChrome(accent)
        let wordmarkGlow = wordmarkColor.opacity(0.48)

        HStack(spacing: 6) {
            ShrugMark(
                size: size,
                accentColor: accentColor,
                accentGlow: accentGlow
            )

            if showsText {
                Text("awesoMux")
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(wordmarkColor)
                    .awGlow(color: wordmarkGlow, radius: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("awesoMux")
    }
}

private struct ShrugMark: View {
    let size: CGFloat
    let accentColor: Color
    let accentGlow: Color

    var body: some View {
        // ツ (katakana "tsu") is the brand glyph — the smile that anchors the
        // ¯\_(ツ)_/¯ wordmark and matches the app icon's face. SF Mono has no
        // katakana, so the system substitutes its CJK face to draw it: the
        // .monospaced/.bold below only seed that substitution. Sized to 0.9em so
        // the full-width advance (~1em) sits inside the size×size box.
        Text("\u{30C4}")
            .font(.system(size: size * 0.9, weight: .bold, design: .monospaced))
            .foregroundStyle(accentColor)
            .frame(width: size, height: size)
            .awGlow(color: accentGlow.opacity(0.65), radius: 5)
            .accessibilityHidden(true)
    }
}
