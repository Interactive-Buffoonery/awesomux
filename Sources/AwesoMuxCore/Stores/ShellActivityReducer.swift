import AwesoMuxBridgeProtocol
import Foundation

struct ShellActivityReducer: Sendable {
    struct DebounceState: Sendable {
        var pendingActivity: ShellActivity?
        var pendingSince: Date?
    }

    // Per-pane debounce state (INT-504 R4): a split with two shells debounces
    // each independently, so one busy shell never forces its idle sibling busy.
    var debounceStateByPaneID: [TerminalPane.ID: DebounceState] = [:]
    var promptSeenPaneIDs: Set<TerminalPane.ID> = []

    /// `didChange` reports whether any pane's `shellActivity` was actually
    /// rewritten. Callers MUST gate the observed-store write on it: passing the
    /// store's `@Observable` array as `inout` fires observation on every call
    /// (inout copies back on return regardless of mutation), so an unconditional
    /// `reducer.update(&store)` re-renders the whole sidebar on every idle sample
    /// (INT-523 scroll stutter). Run the reducer on a local copy and only publish
    /// when `didChange`.
    mutating func update(
        snapshots: [ShellActivitySnapshot],
        groups: inout [SessionGroup],
        now: Date
    ) -> (hasPendingDebounce: Bool, didChange: Bool) {
        for snapshot in snapshots where !snapshot.isBusy {
            promptSeenPaneIDs.insert(snapshot.paneID)
        }

        // Prompt markers are trusted per pane only after that pane has reported
        // an idle prompt once; the first busy sample after spawn can be noise.
        let busyByPaneID = snapshots.reduce(
            into: [TerminalPane.ID: Bool]()
        ) { busy, snapshot in
            let paneContributesBusy = snapshot.isBusy
                && promptSeenPaneIDs.contains(snapshot.paneID)
            busy[snapshot.paneID, default: false] =
                busy[snapshot.paneID, default: false] || paneContributesBusy
        }
        return update(busyByPaneID: busyByPaneID, groups: &groups, now: now)
    }

    mutating func update(
        busyByPaneID: [TerminalPane.ID: Bool],
        groups: inout [SessionGroup],
        now: Date
    ) -> (hasPendingDebounce: Bool, didChange: Bool) {
        var hasPendingDebounce = false
        var didChange = false
        // Phase 1: compute each pane's target activity (mutates debounce state),
        // separate from the layout mutation so the two don't overlap-access.
        var targetActivityByPaneID: [TerminalPane.ID: ShellActivity] = [:]
        for group in groups {
            for session in group.sessions {
                for pane in session.panes {
                    guard pane.agentKind == .shell else {
                        debounceStateByPaneID[pane.id] = nil
                        targetActivityByPaneID[pane.id] = .idle
                        continue
                    }

                    let rawActivity: ShellActivity = busyByPaneID[pane.id] == true
                        ? .busy
                        : .idle
                    targetActivityByPaneID[pane.id] = debouncedShellActivity(
                        current: pane.shellActivity,
                        raw: rawActivity,
                        paneID: pane.id,
                        now: now
                    )
                    hasPendingDebounce = hasPendingDebounce
                        || debounceStateByPaneID[pane.id]?.pendingActivity != nil
                }
            }
        }

        // Phase 2: apply the computed activities to the panes.
        //
        // Only REASSIGN a session's layout when a pane actually changed. The
        // inner closure already returns unchanged panes, but the outer
        // `layout = mappingPanes { ... }` assignment fires `@Observable`
        // unconditionally (the Observation setter notifies on every write, not
        // just value changes) — so without the `changed` gate, this rewrote every
        // session's layout on every ~250ms shell-activity sample, re-rendering the
        // entire sidebar for 2 idle background shells while the user scrolled an
        // unrelated agent pane (INT-523 scroll stutter — the dominant trigger).
        // We can't gate on `newLayout != oldLayout`: `TerminalPane ==` is a
        // render-only subset that excludes `shellActivity`, so a real busy/idle
        // flip would compare equal and never apply.
        for groupIndex in groups.indices {
            for sessionIndex in groups[groupIndex].sessions.indices {
                var changed = false
                let newLayout = groups[groupIndex].sessions[sessionIndex].layout
                    .mappingPanes { pane in
                        guard let target = targetActivityByPaneID[pane.id],
                              pane.shellActivity != target else {
                            return pane
                        }
                        changed = true
                        var pane = pane
                        pane.shellActivity = target
                        return pane
                    }
                if changed {
                    groups[groupIndex].sessions[sessionIndex].layout = newLayout
                    didChange = true
                }
            }
        }

        return (hasPendingDebounce, didChange)
    }

    mutating func removeDebounce(paneID: TerminalPane.ID) {
        debounceStateByPaneID[paneID] = nil
    }

    mutating func removePromptSeen(paneID: TerminalPane.ID) {
        promptSeenPaneIDs.remove(paneID)
    }

    mutating func prune(livePaneIDs: Set<TerminalPane.ID>) {
        debounceStateByPaneID = debounceStateByPaneID
            .filter { livePaneIDs.contains($0.key) }
        promptSeenPaneIDs = promptSeenPaneIDs
            .filter { livePaneIDs.contains($0) }
    }

    private mutating func debouncedShellActivity(
        current: ShellActivity,
        raw: ShellActivity,
        paneID: TerminalPane.ID,
        now: Date
    ) -> ShellActivity {
        if raw == current {
            debounceStateByPaneID[paneID] = nil
            return current
        }

        let interval = raw == .busy
            ? SessionStore.shellActivityBusyDebounceInterval
            : SessionStore.shellActivityIdleDebounceInterval
        var state = debounceStateByPaneID[
            paneID,
            default: DebounceState()
        ]
        if state.pendingActivity != raw {
            state.pendingActivity = raw
            state.pendingSince = now
            debounceStateByPaneID[paneID] = state
            return current
        }

        guard let pendingSince = state.pendingSince,
              now.timeIntervalSince(pendingSince) >= interval else {
            debounceStateByPaneID[paneID] = state
            return current
        }

        debounceStateByPaneID[paneID] = nil
        return raw
    }
}
