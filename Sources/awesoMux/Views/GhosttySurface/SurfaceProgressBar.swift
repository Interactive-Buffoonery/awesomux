import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Adapted from Ghostty's MIT-licensed macOS `SurfaceProgressBar.swift`.
/// Hand-rolled because upstream found `ProgressView` unreliable on macOS 26.
struct SurfaceProgressBar: View {
    let report: TerminalProgressReport
    // Passed by value from the mount site (which reads `@Environment(\.awAccent)`)
    // instead of an `@Environment` read here: environment invalidation does NOT
    // reliably cross the `.equatable()` gate this view sits behind — live smoke
    // showed the bar stuck on a stale accent after a few flips (PR #428). Riding
    // the compared value makes accent changes repaint via the documented
    // value-diff path.
    let accent: AwAccent

    var renderedProgress: UInt8? {
        if let progress = report.progress {
            return progress
        }

        if report.state == .pause {
            return 100
        }

        return nil
    }

    var accessibilityLabelText: String {
        switch report.state {
        case .error:
            return "Terminal progress - Error"
        case .pause:
            return "Terminal progress - Paused"
        case .indeterminate:
            return "Terminal progress - In progress"
        case .set:
            return "Terminal progress"
        case .remove:
            // Structurally unreachable: `TerminalPaneView` only mounts this
            // bar when `progressReport.isVisible`, and the reducer never
            // stores a `.remove` report on a pane (`PaneLayoutReducer
            // .updatePane`). Handled only for switch exhaustiveness.
            return "Terminal progress"
        }
    }

    var accessibilityValueText: String {
        if let renderedProgress {
            return "\(renderedProgress) percent complete"
        }

        switch report.state {
        case .error:
            return "Operation failed"
        case .pause:
            return "Operation paused at completion"
        case .indeterminate:
            return "Operation in progress"
        case .set:
            return "Indeterminate progress"
        case .remove:
            // Structurally unreachable — see `accessibilityLabelText` above.
            return "Indeterminate progress"
        }
    }

    private var color: Color {
        switch report.state {
        case .error:
            return .red
        case .pause:
            return .orange
        case .remove, .set, .indeterminate:
            return Color.aw.accent(accent)
        }
    }

    // `.error`/`.pause` WITH a percentage draws its own background track
    // here; `.error` WITHOUT one falls through to `BouncingProgressBar`,
    // which draws its own — without the `renderedProgress != nil` check
    // both stack, double-darkening the 0.3-alpha layer versus every other
    // state's single layer. Not `private` — same reasoning as
    // `renderedProgress`: directly unit-tested from `SurfaceProgressReportTests`.
    var showsDeterminateTrack: Bool {
        (report.state == .error || report.state == .pause) && renderedProgress != nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if showsDeterminateTrack {
                    Rectangle()
                        .fill(color.opacity(0.3))
                }

                if let renderedProgress {
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(renderedProgress) / 100,
                            height: geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.2), value: renderedProgress)
                } else {
                    BouncingProgressBar(color: color)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(accessibilityValueText))
    }
}

// Synthesized `==` covers `report` AND `accent` — both stored properties.
// The accent MUST participate in equality: this view sits behind
// `.equatable()` in `TerminalPaneView`, and `@Environment` invalidation
// proved unreliable across that gate (stale-accent bug caught in PR #428's
// live smoke), so accent changes repaint via the value-diff path instead.
// Still lets `TerminalPaneView` skip re-rendering the bar for a sibling
// pane's unrelated update, mirroring `PaneTitleBarView`.
extension SurfaceProgressBar: Equatable {}

private struct BouncingProgressBar: View {
    let color: Color
    @State private var position: CGFloat = 0
    // Mirrors `SplitDivider` (`TerminalPaneView.swift`) — the only other
    // infinitely-looping animation in this file tree already gates itself
    // on Reduce Motion the same way.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidthRatio: CGFloat = 0.25

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(color.opacity(0.3))

                Rectangle()
                    .fill(color)
                    .frame(
                        width: geometry.size.width * barWidthRatio,
                        height: geometry.size.height
                    )
                    .offset(x: position * (geometry.size.width * (1 - barWidthRatio)))
            }
        }
        .onAppear {
            guard !reduceMotion else {
                // Static, centered indicator instead of the infinite bounce —
                // still communicates "indeterminate progress" without motion.
                position = 0.5
                return
            }
            withAnimation(
                .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
            ) {
                position = 1
            }
        }
        .onDisappear {
            position = 0
        }
    }
}
