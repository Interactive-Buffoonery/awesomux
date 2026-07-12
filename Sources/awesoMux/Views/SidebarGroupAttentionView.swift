import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Group-level attention rollup shown on a collapsed group's header in the
/// rail, where the group's workspace rows — and their per-tile badges — are
/// hidden. Speaks the same glyph language as `AgentTile`'s collapsed badge via
/// `CollapsedStatusBadge.resolve`, so the rail reads consistently whether a
/// group is expanded (per-tile badges) or collapsed (this rollup).
///
/// `.needs` / `.error` breathe — the `StatusDot.needs` pulse, driven off
/// `.shadow` rather than `awGlow` so the signal survives reduce-transparency
/// and increased-contrast (where `awGlow` drops out entirely). `.thinking`
/// shows a calm, static dot: "working" isn't "needs you", so it doesn't earn
/// the urgency pulse.
struct RailGroupAttentionBadge: View {
    let state: AwState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    /// Only true attention states breathe; thinking stays calm.
    private var breathes: Bool { state == .needs || state == .error }

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color)
                .overlay {
                    Circle().stroke(Color.aw.surface.sidebar, lineWidth: 1)
                }
                .frame(width: 11, height: 11)

            if case .glyph(let glyph)? = CollapsedStatusBadge.resolve(for: state) {
                Text(glyph.rawValue)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.aw.status.onLoud)
            }
        }
        .shadow(
            color: state.color.opacity(breathes ? (reduceMotion ? 0.5 : (isPulsing ? 0.7 : 0.3)) : 0),
            radius: breathes ? (reduceMotion ? 4 : (isPulsing ? 7 : 2)) : 0
        )
        // The badge stays mounted while `state` changes beneath it — same view
        // type and position in the rail header, so SwiftUI reuses the instance
        // and keeps `isPulsing`. The pulse therefore has to re-sync on the state
        // that drives `breathes`, not just on mount: without the `breathes`
        // watch, a `.thinking → .needs` escalation (the ordinary agent lifecycle)
        // would render a static, non-breathing "!", and the reverse would leave a
        // repeatForever loop ticking after the state had already settled. (Unlike
        // `StatusDot`, whose `switch` mounts a fresh instance per state, this one
        // body serves every state, so it must do the watching itself.)
        .onChange(of: reduceMotion, initial: true) { _, _ in syncPulse() }
        .onChange(of: breathes) { _, _ in syncPulse() }
        .onDisappear {
            // Stop the repeatForever loop so a recycled instance starts clean.
            withAnimation(.linear(duration: 0)) { isPulsing = false }
        }
        // Spoken via the group header's accessibilityValue (collapsedStatePhrase);
        // a separate element here would just double-speak.
        .accessibilityHidden(true)
    }

    private func syncPulse() {
        guard breathes, !reduceMotion else {
            // Re-assign inside a zero-duration animation so an already-installed
            // repeatForever animation is actually torn down, not left ticking.
            withAnimation(.linear(duration: 0)) { isPulsing = false }
            return
        }
        withAnimation(AwAnimation.pulseNeeds) { isPulsing = true }
    }
}

/// Counts of the attention states a collapsed group rolls up. `primaryState`
/// resolves the single state the badge/dot renders, ordered needs > error >
/// thinking (matching `AwState`'s own priority).
struct CollapsedGroupAttention {
    var needs = 0
    var error = 0
    var thinking = 0

    var primaryState: AwState? {
        if needs > 0 { return .needs }
        if error > 0 { return .error }
        if thinking > 0 { return .thinking }
        return nil
    }
}
