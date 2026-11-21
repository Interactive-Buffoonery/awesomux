import AwesoMuxCore
import SwiftUI

private enum PaneMotionSpace {
    static let name = "terminal-pane-motion"
}

private struct PaneFramesKey: PreferenceKey {
    static let defaultValue: [TerminalPane.ID: CGRect] = [:]

    static func reduce(value: inout [TerminalPane.ID: CGRect], nextValue: () -> [TerminalPane.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PaneMotion: Equatable {
    let generation: Int
    let axis: Axis
}

extension EnvironmentValues {
    @Entry fileprivate var paneMotionEnabled = false
    @Entry fileprivate var paneMotions: [TerminalPane.ID: PaneMotion] = [:]
}

struct TerminalPaneMotion: ViewModifier {
    let sessionID: TerminalSession.ID
    let paneIDs: [TerminalPane.ID]
    let enabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredSessionID: TerminalSession.ID?
    @State private var previousFrames: [TerminalPane.ID: CGRect] = [:]
    @State private var motions: [TerminalPane.ID: PaneMotion] = [:]
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: PaneMotionSpace.name)
            .environment(\.paneMotionEnabled, enabled && !reduceMotion)
            .environment(\.paneMotions, motions)
            .onPreferenceChange(PaneFramesKey.self, perform: updateFrames)
            .onChange(of: enabled && !reduceMotion) {
                motions = [:]
                previousFrames = [:]
            }
    }

    private func updateFrames(_ frames: [TerminalPane.ID: CGRect]) {
        guard enabled, !reduceMotion, Set(frames.keys) == Set(paneIDs) else { return }
        defer {
            previousFrames = frames
            measuredSessionID = sessionID
        }

        guard measuredSessionID == sessionID else {
            motions = [:]
            return
        }
        let before = Set(previousFrames.keys)
        let after = Set(frames.keys)
        let inserted = after.subtracting(before)
        let removed = before.subtracting(after)
        guard (inserted.count == 1 && removed.isEmpty) || (removed.count == 1 && inserted.isEmpty),
            !before.isEmpty
        else {
            motions = [:]
            return
        }

        generation += 1
        motions = frames.reduce(into: [:]) { result, entry in
            let (id, frame) = entry
            // Newly inserted panes use the old pane under their center as the
            // reference. Surviving panes can reveal even when only size changes.
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let old = previousFrames[id] ?? previousFrames.values.first(where: { $0.contains(center) }),
                old != frame,
                frame.width > 0, frame.height > 0
            else { return }
            let horizontalChange = abs(old.minX - frame.minX) + abs(old.maxX - frame.maxX)
            let verticalChange = abs(old.minY - frame.minY) + abs(old.maxY - frame.maxY)
            result[id] = PaneMotion(generation: generation, axis: horizontalChange >= verticalChange ? .horizontal : .vertical)
        }
    }
}

struct TerminalPaneMotionEffect: ViewModifier {
    let paneID: TerminalPane.ID

    @Environment(\.paneMotionEnabled) private var enabled
    @Environment(\.paneMotions) private var motions
    @Environment(\.terminalBackgroundColor) private var terminalBackgroundColor

    func body(content: Content) -> some View {
        let motion = enabled ? motions[paneID] : nil
        content
            .overlay {
                if enabled {
                    // A moving cover reveals the final layout without shifting
                    // the native surface, focus chrome, or drop targets.
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(terminalBackgroundColor.opacity(motion == nil ? 0 : 0.75))
                            .keyframeAnimator(initialValue: CGFloat(1), trigger: motion) { cover, progress in
                                cover.offset(
                                    x: motion?.axis == .horizontal ? geometry.size.width * progress : 0,
                                    y: motion?.axis == .vertical ? geometry.size.height * progress : 0
                                )
                            } keyframes: { _ in
                                MoveKeyframe(0)
                                CubicKeyframe(1, duration: 0.10)
                            }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .background {
                if enabled {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: PaneFramesKey.self,
                            value: [paneID: geometry.frame(in: .named(PaneMotionSpace.name))]
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}
