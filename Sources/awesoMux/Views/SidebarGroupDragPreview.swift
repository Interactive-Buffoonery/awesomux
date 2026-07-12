import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SidebarGroupDragPreview: View {
    let name: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(name)
                .awFont(AwFont.Mono.kicker)
                .tracking(1)
                .textCase(.uppercase)
                .lineLimit(1)

            Text("\(count)")
                .awFont(AwFont.Mono.meta)
                .monospacedDigit()
                .foregroundStyle(Color.aw.textFaint)
        }
        .foregroundStyle(Color.aw.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(Color.aw.surface.elevated.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.75), lineWidth: 1)
        }
    }
}
