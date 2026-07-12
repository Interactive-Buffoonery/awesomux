import DesignSystem
import SwiftUI

struct ShortcutChordView: View {
    let binding: KeyBinding

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(binding.displayTokens.enumerated()), id: \.offset) { _, token in
                KBD(token)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(binding.spokenForm)
    }
}
