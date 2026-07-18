import DesignSystem
import SwiftUI

/// Three- or four-option picker rendered as a horizontal capsule of segments
/// with the selected segment filled in `accentSoft(...)`. Used for the
/// "subtle / medium / loud" style choices the handoff calls for (notification
/// posture, agent posture, etc).
struct SettingsSegmented<Value: Hashable>: View {
    let options: [Option]
    @Binding var selection: Value
    // Off by default: Settings' three existing call sites size to content and
    // sit beside a label, so stretching them would be a visual regression.
    // Callers that need the control to span its container (equal-width
    // segments, no dead space) opt in explicitly.
    var expandsToFill: Bool = false
    @Environment(\.awAccent) private var accentResolver

    struct Option: Identifiable {
        let value: Value
        let label: String
        var systemImage: String?
        var accessibilityLabel: String? = nil
        var accessibilityHint: String? = nil

        var id: Value { value }
    }

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }
    private var accentSoftColor: Color { Color.aw.accentSoft(accentResolver.accent) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                segmentButton(option)
                    .frame(maxWidth: expandsToFill ? .infinity : nil)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AwRadius.button)
                .fill(Color.aw.surface.elevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func segmentButton(_ option: Option) -> some View {
        let isSelected = option.value == selection
        let button = Button {
            selection = option.value
        } label: {
            HStack(spacing: 6) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(option.label)
                    .awFont(AwFont.UI.meta)
            }
            .foregroundStyle(isSelected ? Color.aw.text : Color.aw.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: AwRadius.button - 1)
                    .fill(isSelected ? accentSoftColor : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AwRadius.button - 1)
                        .stroke(accentColor.opacity(0.4), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.accessibilityLabel ?? option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])

        // Only attach a hint when one is provided — `.accessibilityHint("")`
        // applies an empty hint to every segment of every SettingsSegmented
        // (notification posture, agent posture, …), not "no hint".
        if let hint = option.accessibilityHint {
            button.accessibilityHint(hint)
        } else {
            button
        }
    }
}
