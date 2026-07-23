import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Darwin
import Foundation
import os

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
        guard
            let configuration = launchSweepConfiguration(
                terminalSettings: terminalSettings,
                isRestoreEnabled: isRestoreEnabled,
                hasUnresolvedRecoveryWarning: hasUnresolvedRecoveryWarning
            )
        else { return }
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
        // Failure must stay distinguishable from "no daemons": treating a
        // failed list as empty would mark every session's status file stale.
        guard let listOutput = await AmxBackend.listSessionsRawOutput() else {
            log.error("daemon GC aborted: session list unavailable")
            return
        }
        let live = DaemonGCPlan.parseAmxList(listOutput)

        // Runs even with zero live daemons — that is exactly the state in
        // which every leaked status file is orphaned. Files for daemons
        // reaped later this sweep wait for the next launch; the leak is the
        // unbounded part, not the one-launch lag. The strict re-parse hands
        // the sweep nil (abort) on any format drift the tolerant parser
        // would silently skip — a dropped live row must not read as
        // "no attached client, delete its file".
        sweepStaleStatusFiles(
            live: DaemonGCPlan.parseAmxListStrict(listOutput),
            gcStart: gcStart
        )

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
        let plan = Array(
            Dictionary(
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

    /// Removes leaked per-attach `*.status.jsonl` files — anything not
    /// protected by an attached client, the grace window, or strict name
    /// attribution (Interactive-Buffoonery/awesomux#184). Decision logic
    /// lives in `DaemonGCPlan.staleStatusFiles`; this is the IO.
    /// `live` is nil when the session list failed OR parsed non-strictly —
    /// both abort, deleting nothing. Internal (not private) with an
    /// injectable directory so the abort-on-nil and deletion behavior are
    /// testable against a temp directory.
    // ponytail: blocking FileManager IO on the cooperative pool — launch-once,
    // .utility, O(directory entries); hop to a DispatchQueue if the launch
    // scan ever stalls.
    nonisolated static func sweepStaleStatusFiles(
        live: [LiveDaemon]?,
        gcStart: Int,
        directory: String = AmxBackend.sessionSocketDirectory()
    ) {
        guard let live else {
            log.error("status-file GC skipped: session list unavailable or unparseable")
            return
        }
        let attached = Set(live.filter { $0.clients > 0 }.map(\.id))
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: []
            )
        else { return }
        let candidates = entries.compactMap { url -> DaemonGCPlan.StatusFileCandidate? in
            // Resource values come from the same enumeration pass (one stat
            // per entry) and do not follow symlinks; requiring a regular
            // file keeps a directory or symlink squatting a status-shaped
            // name out of candidacy.
            guard url.lastPathComponent.hasSuffix(".status.jsonl"),
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { return nil }
            return DaemonGCPlan.StatusFileCandidate(
                filename: url.lastPathComponent,
                modifiedEpoch: Int(modified.timeIntervalSince1970)
            )
        }
        let stale = DaemonGCPlan.staleStatusFiles(
            candidates: candidates,
            attached: attached,
            gcStart: gcStart
        )
        guard !stale.isEmpty else { return }
        var removed = 0
        for name in stale {
            // unlink(2), not FileManager.removeItem: refuses directories at
            // the syscall even if the entry changed type after the check
            // above, and unlinks a symlink itself rather than its target.
            if Darwin.unlink(directory + "/" + name) == 0 {
                removed += 1
            } else if errno != ENOENT {
                // ENOENT is the benign race: the file's own watcher removed
                // it first — the desired end state, not an error.
                let errnoValue = errno
                log.error(
                    "status-file GC unlink failed for \(name, privacy: .public): errno=\(errnoValue)"
                )
            }
        }
        log.info("daemon GC: removed \(removed)/\(stale.count) stale status file(s)")
    }
}
