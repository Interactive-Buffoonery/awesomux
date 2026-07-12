import Foundation
import os
import AwesoMuxConfig
import AwesoMuxCore

/// Launch-time orphan daemon GC (INT-570 / ADR-0011). Reaps `amx` daemons that
/// no pane and no reopen entry can reach AND that are idle and unattached;
/// spares busy/attached daemons for the future session-manager UI. The only
/// main-actor work is snapshotting the owned set; everything else runs off-main.
@MainActor
enum DaemonGarbageCollector {
    nonisolated private static let log = Logger(subsystem: "awesomux.daemon", category: "gc")

    struct LaunchSweepConfiguration: Equatable {
        let capThresholdSeconds: Int?
    }

    /// - Parameters:
    ///   - isRestoreEnabled: when workspace restore is off, `store` is empty and
    ///     every daemon would look orphaned — so GC must not run.
    ///   - hasUnresolvedRecoveryWarning: a corrupt/sanitized snapshot may have
    ///     dropped panes, so their surviving daemons would be misclassified as
    ///     orphans and reaped (data loss). Skip GC until the state is trusted.
    ///   - pinned: daemon IDs the user has pinned as "forever" — exempt from the
    ///     age cap (INT-573). Read from `DaemonPolicyStore.pinnedIDs`.
    ///   - terminalSettings: supplies the optional idle-cap threshold. Current
    ///     command-bridge enablement is deliberately not a cleanup prerequisite:
    ///     turning the bridge off can leave previously created daemons to reap.
    static func sweepIfEnabled(
        store: SessionStore,
        terminalSettings: TerminalConfig,
        isRestoreEnabled: Bool,
        hasUnresolvedRecoveryWarning: Bool,
        pinned: Set<TerminalSessionID>
    ) {
        guard let configuration = launchSweepConfiguration(
            terminalSettings: terminalSettings,
            isRestoreEnabled: isRestoreEnabled,
            hasUnresolvedRecoveryWarning: hasUnresolvedRecoveryWarning
        ) else { return }
        // Snapshot the owned set on the main actor from the SAME store state that
        // drives restore, BEFORE any restore attach can create new daemons.
        let owned = DaemonGCPlan.reachableSessionIDs(
            groups: store.groups,
            recentlyClosed: store.recentlyClosed,
            lastClosedTransient: store.lastClosedTransient
        )
        // Fire-and-forget: bounded internally (BoundedCommandRunner timeouts), safe
        // to abandon on quit — a partial sweep just re-runs next launch, and the
        // pre-kill revalidation keeps it correct. No handle/cancellation needed
        // until sweep grows unbounded work.
        Task.detached(priority: .utility) {
            await sweep(
                owned: owned,
                pinned: pinned,
                capThresholdSeconds: configuration.capThresholdSeconds
            )
        }
    }

    nonisolated static func launchSweepConfiguration(
        terminalSettings: TerminalConfig,
        isRestoreEnabled: Bool,
        hasUnresolvedRecoveryWarning: Bool
    ) -> LaunchSweepConfiguration? {
        guard isRestoreEnabled, !hasUnresolvedRecoveryWarning else { return nil }
        return LaunchSweepConfiguration(
            capThresholdSeconds: terminalSettings.daemonIdleCapEnabled
                ? terminalSettings.daemonIdleCapMinutes * 60
                : nil
        )
    }

    /// `nonisolated` so the orchestration (parsing/planning/kill loop) runs on the
    /// cooperative pool, not back on the main actor between subprocess awaits.
    nonisolated static func sweep(
        owned: Set<TerminalSessionID>,
        pinned: Set<TerminalSessionID>,
        capThresholdSeconds: Int?
    ) async {
        // Sample gcStart AFTER the owned snapshot (taken in sweepIfEnabled) and
        // before the first list, so any daemon a restore-attach creates has
        // created >= gcStart and is fenced out by reapable().
        let gcStart = Int(Date().timeIntervalSince1970)
        let live = await AmxBackend.listSessions()
        guard !live.isEmpty else { return }

        // A nil snapshot means `ps` failed — we cannot prove anything is idle, so
        // abort rather than treat every daemon as childless-and-idle (which would
        // reap live work, exactly when the machine is busiest).
        guard let snapshot = await AmxBackend.currentProcessSnapshot() else {
            log.error("daemon GC aborted: process snapshot unavailable")
            return
        }

        var busy = Set<TerminalSessionID>()
        for daemon in live where !AmxBackend.isIdle(daemon, snapshot: snapshot) {
            busy.insert(daemon.id)
        }

        // idle map for the cap (reuse the snapshot already taken for `busy`).
        var idleByID: [TerminalSessionID: Bool] = [:]
        for daemon in live { idleByID[daemon.id] = AmxBackend.isIdle(daemon, snapshot: snapshot) }

        let orphanPlan = DaemonGCPlan.reapable(live: live, owned: owned, busy: busy, gcStart: gcStart)
        let expiredPlan = DaemonGCPlan.expiredReapable(
            live: live, owned: owned, busy: busy, pinned: pinned, idleByID: idleByID,
            capThresholdSeconds: capThresholdSeconds, now: Int(Date().timeIntervalSince1970), gcStart: gcStart
        )
        // Union by id (a daemon can satisfy both); the existing revalidation below
        // still guards every kill against a fresh list.
        let plan = Array(Dictionary(
            (orphanPlan + expiredPlan).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        ).values)
        guard !plan.isEmpty else { return }

        // Re-validate against a fresh list right before killing: only reap a
        // target whose pid+created are unchanged and which is still unattached,
        // so we never kill a daemon that was reused, restarted, or reattached
        // since the first snapshot. (parseAmxList dedups, so ids are unique here.)
        let confirm = Dictionary(
            (await AmxBackend.listSessions()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let targets = plan.filter { target in
            guard let current = confirm[target.id] else { return false }
            return current.pid == target.pid
                && current.createdEpoch == target.createdEpoch
                && current.clients == 0
        }
        guard !targets.isEmpty else { return }

        // Kills are independent — fan them out so one slow/hung `amx kill` (up to
        // its 2s timeout) doesn't serialize the rest.
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    if !(await AmxBackend.killSession(target.id)) {
                        log.error("reap dispatch failed for \(target.id.rawValue, privacy: .public) pid=\(target.pid)")
                    }
                }
            }
        }

        // Honest accounting: re-list and count how many targets are actually gone,
        // since `amx kill` exiting 0 does not guarantee the daemon died.
        let remaining = Set((await AmxBackend.listSessions()).map(\.id))
        let reaped = targets.filter { !remaining.contains($0.id) }.count
        log.info("daemon GC: \(reaped)/\(targets.count) orphan daemon(s) confirmed reaped")
    }
}
