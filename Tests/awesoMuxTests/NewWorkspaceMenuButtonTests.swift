import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
struct NewWorkspaceMenuButtonTests {
    @Test("button-styled menu renders a centered 40-point control")
    func buttonStyledMenuRendersCenteredControl() throws {
        let size: CGFloat = 40
        let view = NewWorkspaceMenuButton(
            size: size,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        let (window, hostingView) = SidebarHostedTestHarness.makeWindow(
            rootView: view,
            frame: NSRect(x: 0, y: 0, width: size, height: size)
        )
        defer { window.close() }

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        var visiblePixelCount = 0
        var alphaTotal: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                guard alpha > 0.1 else { continue }
                visiblePixelCount += 1
                alphaTotal += alpha
                weightedX += CGFloat(x) * alpha
                weightedY += CGFloat(y) * alpha
            }
        }
        #expect(
            visiblePixelCount < bitmap.pixelsWide * bitmap.pixelsHigh / 4,
            "the transparent probe must isolate the plus instead of measuring an opaque backing"
        )
        try #require(alphaTotal > 0, "the transparent probe must render the plus")
        let renderedMidX = weightedX / alphaTotal
        let renderedMidY = weightedY / alphaTotal
        let bitmapMidX = CGFloat(bitmap.pixelsWide - 1) / 2
        let bitmapMidY = CGFloat(bitmap.pixelsHigh - 1) / 2
        let pixelsPerPointX = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        let pixelsPerPointY = CGFloat(bitmap.pixelsHigh) / hostingView.bounds.height

        if let nativeButton = SidebarHostedTestHarness.firstDescendant(of: NSButton.self, in: hostingView) {
            let frame = nativeButton.convert(nativeButton.bounds, to: hostingView)
            #expect(abs(frame.width - size) <= 0.5)
            #expect(abs(frame.height - size) <= 0.5)
            #expect(abs(frame.midX - hostingView.bounds.midX) <= 0.5)
            #expect(abs(frame.midY - hostingView.bounds.midY) <= 0.5)
        }
        #expect(abs(renderedMidX - bitmapMidX) / pixelsPerPointX <= 0.5)
        #expect(abs(renderedMidY - bitmapMidY) / pixelsPerPointY <= 1)
    }

    @Test("equatable gate ignores closures but tracks size, fill, and group list")
    func equatableGateTracksMeaningfulInputsOnly() {
        let groupID = UUID()
        let base = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )

        // Same values, freshly-allocated closures — this is exactly what
        // every unrelated SidebarView re-render produces. Must compare
        // equal, or the `.equatable()` gate at the call site never
        // actually suppresses anything.
        let sameInputsNewClosures = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base == sameInputsNewClosures)

        let differentSize = NewWorkspaceMenuButton(
            size: 32,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentSize)

        let differentFill = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .black,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentFill)

        let differentGroupName = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Beta")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentGroupName)

        let differentGroupCount = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: .clear,
            otherGroups: [(id: groupID, name: "Alpha"), (id: UUID(), name: "Gamma")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(base != differentGroupCount)
    }

    @Test("equatable gate holds for the real production fill color")
    func equatableGateHoldsForProductionFill() {
        // The trivial static colors above (.clear/.black) don't prove the
        // gate survives the actual call site's dynamic, opacity-derived
        // fill (SidebarView.swift's collapsedSearchHeader passes
        // Color.aw.surface.elevated.opacity(0.6)) — confirm two
        // independently-constructed views with that real color still
        // compare equal, the property the whole gate depends on.
        let productionFill = Color.aw.surface.elevated.opacity(0.6)
        let groupID = UUID()
        let first = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: productionFill,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        let second = NewWorkspaceMenuButton(
            size: 40,
            cornerRadius: 7,
            restFill: productionFill,
            otherGroups: [(id: groupID, name: "Alpha")],
            onNewWorkspace: {},
            onNewWorkspaceInGroup: { _ in },
            onNewWorkspaceGroup: {}
        )
        #expect(first == second)
    }
}
