import DesignSystem
import SwiftUI

struct QuickRunToast: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case finished(exitCode: Int32)
        case failed(String)
    }

    let id: UUID
    let command: String
    var output: String
    var state: State
}

struct QuickRunToastView: View {
    let toast: QuickRunToast

    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stateLabel)
                    .awFont(AwFont.Mono.kicker)
                    .foregroundStyle(stateColor)
                    .textCase(.uppercase)

                Text(toast.command)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
            }

            if !toast.output.isEmpty {
                Text(toast.output)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.aw.surface.chrome.opacity(0.98), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .awShadow(.sheet)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var stateLabel: String {
        switch toast.state {
        case .running:
            "Running"
        case .finished(let exitCode):
            exitCode == 0 ? "Done" : "Exit \(exitCode)"
        case .failed:
            "Failed"
        }
    }

    private var stateColor: Color {
        switch toast.state {
        case .running:
            Color.aw.accent(accentResolver.accent)
        case .finished(let exitCode):
            exitCode == 0 ? Color.aw.teal : Color.aw.red
        case .failed:
            Color.aw.red
        }
    }

    private var accessibilityLabel: String {
        let output = toast.output.isEmpty ? "" : ". \(toast.output)"
        return "\(stateLabel): \(toast.command)\(output)"
    }
}
