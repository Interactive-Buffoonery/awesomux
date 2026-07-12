import DesignSystem
import SwiftUI

/// One label/hint/control row inside a `SettingsSection`. Renders the
/// 200pt label column on the leading edge, hint text immediately under
/// the label, and the caller-provided control on the trailing edge.
///
/// Every row draws a 0.5pt top hairline so consecutive fields read as
/// a vertical stack of dividers — handoff `settings.jsx` contract.
struct SettingsField<Control: View>: View {
    let label: String
    var hint: String?
    /// Per-row overrides for hints that carry content rather than guidance —
    /// the custom-command rows show the actual shell command here, which
    /// needs more contrast than the `text3` guidance default and a cap so a
    /// long one-liner can't stretch the row. Defaults preserve every other
    /// call site.
    var hintColor: Color = Color.aw.text3
    var hintLineLimit: Int?
    var isFirst: Bool = false
    /// Opt-in for *bare* controls that drop their own accessibility name — most
    /// importantly a `.labelsHidden()` Toggle, which removes its label from the
    /// accessibility tree and is otherwise announced as a nameless "switch"
    /// (WCAG 4.1.2). When set, the field forwards `label`/`hint` to the control
    /// as its VoiceOver name + hint and hides the now-redundant visual label
    /// column from assistive tech.
    ///
    /// Off by default: most controls (segmented groups, sliders, pickers,
    /// keystroke rows) already carry their own accessibility, and forwarding a
    /// second name on top of them double-announces or clobbers it. Set this true
    /// only on a control that has no accessibility of its own.
    var forwardsAccessibilityToControl: Bool = false
    /// Only consulted when `forwardsAccessibilityToControl` is true. Set false
    /// when the control supplies its own `.accessibilityHint` — one that varies
    /// with state, or spells a keyboard shortcut out for speech — so the field
    /// forwards only its name and the control's hand-tuned hint survives
    /// instead of being replaced by the field's visual hint text. A control
    /// that opts out must supply its own hint — the settings accessibility
    /// guard test pins that contract.
    var forwardsHintToControl: Bool = true
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(Color.aw.border)
                    .frame(height: 0.5)
            }

            ViewThatFits(in: .horizontal) {
                horizontalLayout
                verticalLayout
            }
            .padding(.vertical, AwSettings.fieldVerticalPadding)
        }
        .accessibilityElement(children: .contain)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            labelColumn
                .frame(width: AwSettings.fieldLabelWidth, alignment: .leading)

            decoratedControl
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            decoratedControl
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var decoratedControl: some View {
        if forwardsAccessibilityToControl {
            // Apply the hint only when there is one — `.accessibilityHint("")`
            // attaches an *empty* hint rather than no hint (same gotcha the
            // SettingsSegmented control documents).
            if let hint, forwardsHintToControl {
                control()
                    .accessibilityLabel(Text(label))
                    .accessibilityHint(Text(hint))
            } else {
                control()
                    .accessibilityLabel(Text(label))
            }
        } else {
            control()
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .fixedSize(horizontal: false, vertical: true)

            if let hint {
                Text(hint)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(hintColor)
                    .lineLimit(hintLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // When the control carries the name+hint (i.e. when forwarding), the visual
        // label column is decorative for AT — hiding it prevents VoiceOver from
        // announcing the label twice (once as orphaned text, once on the
        // control).
        .accessibilityHidden(forwardsAccessibilityToControl)
    }
}
