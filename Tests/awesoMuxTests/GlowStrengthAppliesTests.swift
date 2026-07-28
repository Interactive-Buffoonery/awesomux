import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing

@testable import awesoMux

/// Every colored halo in the app is user-governed by `appearance.glow_strength`:
/// radii scale by it, and `0.0` means the halo is not drawn at all.
///
/// These assert the *rendered* result, not the setting's storage. A halo that
/// bypasses `awGlow` — drawn with a bare `.shadow(color:radius:)` — still reads
/// the same accent and still looks right in isolation, so only counting the
/// pixels it puts outside its own shape can tell the two apart.
@Suite(.serialized)
@MainActor
struct GlowStrengthAppliesTests {
    /// Pixels the view paints outside `core`, which is the view's own layout
    /// footprint. A halo is the only thing that can land there.
    private static func haloPixels(
        _ view: some View,
        canvas: CGSize,
        core: CGSize,
        strength: Double
    ) -> Int {
        let renderer = ImageRenderer(
            content:
                view
                .frame(width: canvas.width, height: canvas.height)
                .awGlowStrength(strength)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced no image")
            return 0
        }

        let width: Int = image.width
        let height: Int = image.height
        let byteCount: Int = width * height * 4
        var pixels = [UInt8](repeating: 0, count: byteCount)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            Issue.record("could not build a bitmap context")
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // One point of slack around the footprint: the renderer antialiases the
        // shape's own edge, and that fringe is not a halo.
        let marginX: Int = (width - Int(core.width)) / 2 - 1
        let marginY: Int = (height - Int(core.height)) / 2 - 1
        var count = 0
        for y in 0..<height {
            let outsideRow: Bool = y < marginY || y >= height - marginY
            for x in 0..<width {
                let outsideColumn: Bool = x < marginX || x >= width - marginX
                guard outsideRow || outsideColumn else { continue }
                let alpha: UInt8 = pixels[(y * width + x) * 4 + 3]
                if alpha > 4 { count += 1 }
            }
        }
        return count
    }

    @Test("the status dot's attention halo scales with glow strength")
    func statusDotHalo() {
        let dot = StatusDot(.needs)
        let canvas = CGSize(width: 60, height: 60)
        let core = CGSize(width: 14, height: 14)
        // Positive control: without it, a harness that renders nothing at all
        // would satisfy the OFF assertion below for the wrong reason.
        #expect(Self.haloPixels(dot, canvas: canvas, core: core, strength: 1.0) > 0)
        #expect(Self.haloPixels(dot, canvas: canvas, core: core, strength: 0.0) == 0)
    }

    @Test("the collapsed group's attention halo scales with glow strength")
    func railGroupAttentionHalo() {
        let badge = RailGroupAttentionBadge(state: .needs)
        let canvas = CGSize(width: 60, height: 60)
        let core = CGSize(width: 11, height: 11)
        #expect(Self.haloPixels(badge, canvas: canvas, core: core, strength: 1.0) > 0)
        #expect(Self.haloPixels(badge, canvas: canvas, core: core, strength: 0.0) == 0)
    }

    @Test("the focus ring's accent halo scales with glow strength")
    func focusRingHalo() {
        let ring = Color.aw.surface.elevated
            .frame(width: 30, height: 30)
            .awFocusRing(true, cornerRadius: 6)
        let canvas = CGSize(width: 70, height: 70)
        let core = CGSize(width: 30, height: 30)
        #expect(Self.haloPixels(ring, canvas: canvas, core: core, strength: 1.0) > 0)
        #expect(Self.haloPixels(ring, canvas: canvas, core: core, strength: 0.0) == 0)
    }

    /// The surface #286 was filed against. Its halo already went through
    /// `awGlow`, so it always honoured the setting — but only when it draws one
    /// at all: a merely-focused pane's halo is gated behind `cursor_glow`, which
    /// ships off, leaving nothing for the strength to scale. `.needs` is the
    /// state that has a halo at shipped defaults.
    @Test("the pane focus rail's attention halo scales with glow strength")
    func paneFocusRailHalo() {
        let rail = PaneFocusAccent(state: .needs, differentiateWithoutColor: false)
            .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
        let canvas = CGSize(width: 40, height: 40)
        let core = CGSize(width: 40, height: PaneFocusAccent.reservedHeight)
        #expect(Self.haloPixels(rail, canvas: canvas, core: core, strength: 1.0) > 0)
        #expect(Self.haloPixels(rail, canvas: canvas, core: core, strength: 0.0) == 0)
    }

    @Test("the drag insertion indicator's tint halo scales with glow strength")
    func insertionIndicatorHalo() {
        let indicator = SidebarInsertionIndicatorBody(tint: Color.aw.peach, shadowOpacity: 0.28)
            .frame(width: 40, height: 8)
        let canvas = CGSize(width: 80, height: 40)
        let core = CGSize(width: 40, height: 8)
        #expect(Self.haloPixels(indicator, canvas: canvas, core: core, strength: 1.0) > 0)
        #expect(Self.haloPixels(indicator, canvas: canvas, core: core, strength: 0.0) == 0)
    }
}
