extension TerminalPaneLayout {
    /// Adjust surviving, untouched dividers whose same-axis lane counts changed.
    /// A perpendicular subtree or a manually sized split occupies one lane.
    func resizingAfterPaneCountChange(from previous: TerminalPaneLayout) -> TerminalPaneLayout {
        guard self != previous, case let .split(split) = self else { return self }
        let oldSplit = previous.split(id: split.id)

        let first = oldSplit.map { split.first.resizingAfterPaneCountChange(from: $0.first) } ?? split.first
        let second = oldSplit.map { split.second.resizingAfterPaneCountChange(from: $0.second) } ?? split.second
        let firstCount = first.automaticLaneCount(along: split.orientation)
        let secondCount = second.automaticLaneCount(along: split.orientation)
        let countChanged =
            firstCount != oldSplit?.first.automaticLaneCount(along: split.orientation)
            || secondCount != oldSplit?.second.automaticLaneCount(along: split.orientation)

        // Model operations also run for hidden workspaces, where pane geometry
        // is unavailable. Use proportional space and retain the existing clamps.
        let fraction =
            !split.preservesFraction && countChanged
            ? Double(firstCount) / Double(firstCount + secondCount)
            : split.firstFraction
        return .split(split.rebuilding(first: first, second: second, firstFraction: fraction))
    }

    private func automaticLaneCount(along orientation: TerminalSplitOrientation) -> Int {
        guard case let .split(split) = self, split.orientation == orientation, !split.preservesFraction
        else { return 1 }
        return split.first.automaticLaneCount(along: orientation)
            + split.second.automaticLaneCount(along: orientation)
    }
}
