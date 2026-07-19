import AwesoMuxCore
import DesignSystem
import SwiftUI

/// PreferenceKey used by `SidebarGroupView` to cache each rendered tile's
/// frame in the group's local coordinate space. Drives the y-hit-test that
/// turns a drop point into an insert index.
struct SidebarRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [TerminalSession.ID: CGRect] = [:]
    static func reduce(
        value: inout [TerminalSession.ID: CGRect],
        nextValue: () -> [TerminalSession.ID: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SidebarGroupFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SessionGroup.ID: CGRect] = [:]
    static func reduce(
        value: inout [SessionGroup.ID: CGRect],
        nextValue: () -> [SessionGroup.ID: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Keeps the latest preference value without publishing a SwiftUI state change.
/// A newly-active drag can read this immediately while its gated `@State` cache
/// catches up, so an unchanged preference value cannot leave the first hover
/// without geometry.
final class SidebarDragFrameCache<ID: Hashable> {
    private var latest: [ID: CGRect] = [:]

    func update(_ frames: [ID: CGRect]) {
        latest = frames
    }

    func frames(stored: [ID: CGRect], isDragActive: Bool) -> [ID: CGRect] {
        isDragActive ? latest : stored
    }
}

enum SidebarInsertionResolver {
    static func insertionIndex<ID: Hashable>(
        forDropY y: CGFloat,
        orderedIDs: [ID],
        frames: [ID: CGRect]
    ) -> Int? {
        // No usable layout data yet (cache empty, or every cached frame is
        // zero-height because the rows just materialized and the frame
        // preference hasn't propagated). Returning `orderedIDs.count` here
        // would silently bias the drop to the END of the list — a wrong
        // landing, not a safe one. Return nil so the caller holds (no
        // indicator, no move) until real frames arrive.
        guard frames.values.contains(where: { $0.height > 0 }) else {
            return nil
        }

        var fallbackIndex = orderedIDs.count
        for (offset, id) in orderedIDs.enumerated() {
            guard let frame = frames[id] else { continue }
            fallbackIndex = offset + 1
            if y <= frame.midY {
                return offset
            }
            if y > frame.midY {
                fallbackIndex = offset + 1
            }
        }
        return min(fallbackIndex, orderedIDs.count)
    }

    static func insertionY<ID: Hashable>(
        forInsertionIndex index: Int,
        orderedIDs: [ID],
        frames: [ID: CGRect],
        spacing: CGFloat
    ) -> CGFloat? {
        guard !orderedIDs.isEmpty,
              !frames.isEmpty else {
            return nil
        }

        let clampedIndex = max(0, min(index, orderedIDs.count))
        let previousFrame = clampedIndex > 0
            ? frames[orderedIDs[clampedIndex - 1]]
            : nil
        let nextFrame = clampedIndex < orderedIDs.count
            ? frames[orderedIDs[clampedIndex]]
            : nil

        if let previousFrame, let nextFrame {
            return (previousFrame.maxY + nextFrame.minY) / 2
        }
        if let nextFrame {
            return nextFrame.minY - spacing / 2
        }
        if let previousFrame {
            return previousFrame.maxY + spacing / 2
        }

        return nil
    }

    static func visibleReorderInsertionIndex<ID: Equatable>(
        candidateIndex: Int,
        sourceID: ID?,
        orderedIDs: [ID]
    ) -> Int? {
        let clampedIndex = max(0, min(candidateIndex, orderedIDs.count))
        guard let sourceID,
              let sourceIndex = orderedIDs.firstIndex(of: sourceID) else {
            return clampedIndex
        }

        let targetIndex = postRemovalTargetIndex(
            sourceIndex: sourceIndex,
            preRemovalIndex: clampedIndex
        )
        return targetIndex == sourceIndex ? nil : clampedIndex
    }

    static func postRemovalTargetIndex(sourceIndex: Int, preRemovalIndex: Int) -> Int {
        sourceIndex < preRemovalIndex ? preRemovalIndex - 1 : preRemovalIndex
    }

    static func workspacePostRemovalTargetIndex<ID: Hashable>(
        sourceID: ID,
        dropPoint: CGPoint,
        preRemovalIndex: Int,
        orderedIDs: [ID],
        frames: [ID: CGRect]
    ) -> Int? {
        if let sourceFrame = frames[sourceID],
           sourceFrame.contains(dropPoint) {
            return nil
        }

        guard let sourceIndex = orderedIDs.firstIndex(of: sourceID) else {
            return preRemovalIndex
        }
        let targetIndex = postRemovalTargetIndex(
            sourceIndex: sourceIndex,
            preRemovalIndex: preRemovalIndex
        )
        return targetIndex == sourceIndex ? nil : targetIndex
    }
}

struct SidebarInsertionIndicator: View {
    static let height: CGFloat = 8

    let tint: Color

    var body: some View {
        SidebarInsertionIndicatorBody(tint: tint, shadowOpacity: 0.28)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityHidden(true)
    }
}

struct SidebarGroupInsertionIndicator: View {
    static let height: CGFloat = 8

    let tint: Color

    var body: some View {
        SidebarInsertionIndicatorBody(tint: tint, shadowOpacity: 0.26)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityHidden(true)
    }
}

struct SidebarInsertionIndicatorBody: View {
    let tint: Color
    let shadowOpacity: Double

    var body: some View {
        HStack(spacing: 5) {
            dot

            line

            dot
        }
        .shadow(color: tint.opacity(shadowOpacity), radius: 3, y: 1)
    }

    private var dot: some View {
        Circle()
            .fill(Color.aw.dividerHover)
            .frame(width: 5.5, height: 5.5)
            .overlay {
                Circle()
                    .fill(tint)
                    .frame(width: 3.5, height: 3.5)
            }
    }

    private var line: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.1)
                .fill(Color.aw.dividerHover)
                .frame(height: 2.2)

            RoundedRectangle(cornerRadius: 0.5)
                .fill(tint)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}
