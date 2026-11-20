import Foundation

extension TerminalPaneLayout {
    /// Equalizes lanes in each contiguous same-axis run. Each split clamps
    /// its target and can move inward when rounding lands on a minimum. Its
    /// children retarget within their allocated space.
    func balancingSplits(in size: CGSize) -> (layout: TerminalPaneLayout, changed: Bool)? {
        guard case .split = self,
            size.width.isFinite, size.width > 0,
            size.height.isFinite, size.height > 0
        else { return nil }
        return BalanceSizing(self).allocating(size)
    }
}

private struct BalanceSizing {
    // Match TerminalSplitLayoutView's one-point divider.
    private static let divider = 1.0

    private indirect enum Node {
        case leaf(TerminalPaneLayout)
        case split(TerminalSplit, BalanceSizing, BalanceSizing)
    }

    private let node: Node
    private let minimum: CGSize
    private let lanes: Int

    init(_ layout: TerminalPaneLayout) {
        guard case let .split(split) = layout else {
            self.node = .leaf(layout)
            self.minimum = .zero
            self.lanes = 1
            return
        }
        let first = BalanceSizing(split.first)
        let second = BalanceSizing(split.second)
        let axis = split.orientation.balanceAxis
        let a = Double(first.minimum[keyPath: axis])
        let b = Double(second.minimum[keyPath: axis])
        let halfDivider = Self.divider / 2

        var minimum = CGSize(
            width: max(first.minimum.width, second.minimum.width),
            height: max(first.minimum.height, second.minimum.height)
        )
        minimum[keyPath: axis] = CGFloat(
            max(
                a + b + Self.divider,
                (a + halfDivider) / TerminalSplit.fractionRange.upperBound,
                (b + halfDivider) / TerminalSplit.fractionRange.upperBound
            ))
        self.node = .split(split, first, second)
        self.minimum = minimum
        self.lanes = first.laneCount(along: split.orientation) + second.laneCount(along: split.orientation)
    }

    private func laneCount(along orientation: TerminalSplitOrientation) -> Int {
        guard case let .split(split, _, _) = node, split.orientation == orientation else { return 1 }
        return lanes
    }

    func allocating(_ size: CGSize) -> (layout: TerminalPaneLayout, changed: Bool)? {
        switch node {
        case let .leaf(layout):
            return (layout, false)
        case let .split(split, first, second):
            let axis = split.orientation.balanceAxis
            let length = Double(size[keyPath: axis])
            let firstLanes = Double(first.laneCount(along: split.orientation))
            let laneLength = (length - Double(lanes - 1) * Self.divider) / Double(lanes)
            let target = (firstLanes * laneLength + (firstLanes - 1) * Self.divider + Self.divider / 2) / length

            guard
                let allocation = Self.allocation(
                    length: length,
                    target: target,
                    firstMinimum: Double(first.minimum[keyPath: axis]),
                    secondMinimum: Double(second.minimum[keyPath: axis])
                )
            else { return nil }

            var firstSize = size
            var secondSize = size
            firstSize[keyPath: axis] = CGFloat(allocation.first)
            secondSize[keyPath: axis] = CGFloat(allocation.second)
            guard let firstResult = first.allocating(firstSize),
                let secondResult = second.allocating(secondSize)
            else { return nil }

            let changed = split.firstFraction != allocation.fraction || firstResult.changed || secondResult.changed
            guard changed else { return (.split(split), false) }
            let rebuilt = split.rebuilding(
                first: firstResult.layout,
                second: secondResult.layout,
                firstFraction: allocation.fraction
            )
            return (.split(rebuilt), true)
        }
    }

    private static func allocation(
        length: Double,
        target: Double,
        firstMinimum: Double,
        secondMinimum: Double
    ) -> (fraction: Double, first: Double, second: Double)? {
        let halfDivider = divider / 2
        let lower = max(TerminalSplit.fractionRange.lowerBound, (firstMinimum + halfDivider) / length)
        let upper = min(TerminalSplit.fractionRange.upperBound, 1 - (secondMinimum + halfDivider) / length)
        guard target.isFinite, lower <= upper else { return nil }

        typealias Allocation = (fraction: Double, first: Double, second: Double)

        func extents(_ fraction: Double) -> Allocation {
            // Keep the renderer's operation order on both sides of the divider.
            (fraction, length * fraction - halfDivider, length * (1 - fraction) - halfDivider)
        }

        func meetsClosedBounds(_ candidate: Allocation) -> Bool {
            candidate.first >= firstMinimum && candidate.second >= secondMinimum
                && candidate.first > 0 && candidate.second > 0
        }

        let nearest = extents(min(max(target, lower), upper))
        if nearest.first > firstMinimum, nearest.second > secondMinimum {
            return nearest
        }

        // A computed endpoint can render onto the closed boundary. Move inward
        // by one ULP first, then try the interval midpoint if rounding still binds.
        let inward = nearest.first <= firstMinimum ? nearest.fraction.nextUp : nearest.fraction.nextDown
        var boundary = meetsClosedBounds(nearest) ? nearest : nil
        for fraction in [inward, lower + (upper - lower) / 2] where lower <= fraction && fraction <= upper {
            let candidate = extents(fraction)
            if candidate.first > firstMinimum, candidate.second > secondMinimum {
                return candidate
            }
            if boundary == nil, meetsClosedBounds(candidate) {
                boundary = candidate
            }
        }

        // Descending the tree verifies whether a closed internal boundary
        // actually admits positive leaf extents.
        return boundary
    }
}

private extension TerminalSplitOrientation {
    var balanceAxis: WritableKeyPath<CGSize, CGFloat> {
        switch self {
        case .vertical: \.width
        case .horizontal: \.height
        }
    }
}
