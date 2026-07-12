import DesignSystem
import SwiftUI

/// Side-by-side Unicode/punycode host display for the OSC 8 block-confirm
/// modal (INT-452). Shown instead of the plain "Display:"/"Resolves to:"
/// body lines when the two forms of an IDN host differ, so the spoofable
/// form and the form that actually resolves are visually comparable.
/// Hosts must be pre-sanitized by the caller (`sanitizedForAlertBody`).
struct BlockedURLHostComparisonView: View {
    let displayHost: String
    let punycodeHost: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            hostRow(
                label: String(
                    localized: "Display",
                    comment: "Label for the Unicode form of an IDN host in the OSC 8 confirmation modal."
                ),
                host: "\u{2068}\(displayHost)\u{2069}",
                emphasized: false
            )
            hostRow(
                label: String(
                    localized: "Resolves to",
                    comment: "Label for the punycode form an IDN host actually resolves to in the OSC 8 confirmation modal."
                ),
                host: punycodeHost,
                emphasized: true
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .fill(Color.aw.surface.elevated)
        )
        .accessibilityElement(children: .combine)
    }

    private func hostRow(label: String, host: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text3)
                .frame(width: 84, alignment: .trailing)
            Text(host)
                .awFont(AwFont.Mono.body)
                .foregroundStyle(emphasized ? Color.aw.peach : Color.aw.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
