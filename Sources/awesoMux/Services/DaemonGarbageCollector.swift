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
        let strictLive = DaemonGCPlan.parseAmxListStrict(listOutput)
        sweepStaleStatusFiles(live: strictLive, gcStart: gcStart)
        // Logs (unlike status files) reuse one path per session NAME, so a dead
        // session's log can be reopened by a daemon restore recreates for the
        // SAME id between the list snapshot and unlink. `owned` (captured
        // pre-restore in sweepIfEnabled) is exactly that recreation set, so
        // sparing it closes the resurrection window without a second list.
        sweepSessionLogs(live: strictLive, owned: owned, gcStart: gcStart)

        guard !live.isEmpty else { return }

        // A nil snapshot means `ps` failed — we cannot prove anything is idle, so
        // abort rather than treat every daemon as childless-and-idle (which would
        // reap live work, exactly when the machine is busiest).
        guard let snapshot = await AmxBackend.currentProcessSnapshot() else {
            log.error("daemon GC aborted: process snapshot unavailable")
            return
        }

        // Independent of the daemon-reap plan below on purpose: the primary
        // #183 scenario is a daemon PERMANENTLY pinned at clients >= 1 by its
        // orphaned client, so `reapable`/`expiredReapable` never select it and
        // `plan`/`targets` below can be empty on every sweep. Gating this
        // behind either of those guards' early returns would make the orphan
        // cleanup unreachable in exactly the case it exists to fix — caught
        // in review before shipping, not discovered live.
        await reapOrphanAttachClients(live: live, snapshot: snapshot)

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

    /// Terminates leaked `amx attach` clients reparented to launchd
    /// (Interactive-Buffoonery/awesomux#183): each one pins its daemon's
    /// `clients` count >= 1 forever, permanently defeating `reapable` above.
    /// Own-profile leaks only: the confirm pass requires the session's socket
    /// to live in THIS profile's directory, so a sister profile's orphaned
    /// `amx` processes are never this sweep's to kill (Interactive-Buffoonery/awesomux#277).
    /// `snapshot` is the one already fetched for busy/idle classification —
    /// the shortlist pass costs nothing extra; the confirm pass below only
    /// runs when that shortlist is non-empty (rare — real orphans are
    /// hours-to-days old per the issue's own observed data).
    nonisolated private static func reapOrphanAttachClients(
        live: [LiveDaemon],
        snapshot: [ProcEntry]
    ) async {
        // A daemon whose own pid we cannot resolve is indistinguishable from a
        // leaked attach client here, and it is missing from the very set that
        // would spare it — so skip, exactly as the guards below do on
        // unreadable input. Reachable in production: `currentProcessSnapshot()`
        // caps `ps` at 4 MB and a truncated snapshot silently drops rows.
        guard let daemonPIDs = DaemonGCPlan.liveDaemonPIDs(live: live, snapshot: snapshot) else {
            log.error("orphan attach GC skipped: a live daemon's own pid is unresolvable")
            return
        }
        let candidates = DaemonGCPlan.candidateOrphanAttachPIDs(
            snapshot: snapshot, daemonPIDs: daemonPIDs, executableName: AmxBackend.executableName
        )
        guard !candidates.isEmpty else { return }

        // Revalidate against fresh daemon + process state right before
        // signaling: closes the pid-reuse race between the snapshot above and
        // the kill below (mirrors the daemon-reap revalidation earlier in
        // this function). Strict parse (`parseAmxListStrict`), not the
        // tolerant `parseAmxList` `listSessionsResult()` uses elsewhere —
        // this is a fail-DANGEROUS spot exactly like the status-file sweep
        // above: a tolerant parser silently dropping one live daemon's row
        // would remove that daemon's pid from `freshDaemonPIDs` without any
        // signal something went wrong, and this pass's whole job is telling
        // a live daemon apart from an orphaned client sharing its binary.
        // Format drift must abort the sweep, not fail open into a kill.
        guard let freshListOutput = await AmxBackend.listSessionsRawOutput(),
            let freshDaemons = DaemonGCPlan.parseAmxListStrict(freshListOutput)
        else {
            log.error("orphan attach GC aborted: fresh daemon list unavailable or unparseable")
            return
        }
        // `attachProcessSamples(forPIDs:)` below covers only the candidate
        // attach pids, so it can never resolve the parents of the FRESH listed
        // pids — and those parents are the daemons `liveDaemonPIDs` fences on.
        // Hence a second full snapshot here rather than a reuse. Same
        // fail-dangerous stance as the strict re-parse above: an unavailable
        // snapshot means we cannot tell a daemon from a leaked client, so
        // abort instead of falling open into a kill.
        guard let freshSnapshot = await AmxBackend.currentProcessSnapshot() else {
            log.error("orphan attach GC aborted: fresh process snapshot unavailable")
            return
        }
        // Resolved before the confirm query so an unresolvable daemon aborts
        // without spawning it.
        guard let freshDaemonPIDs = DaemonGCPlan.liveDaemonPIDs(live: freshDaemons, snapshot: freshSnapshot)
        else {
            log.error("orphan attach GC aborted: a fresh live daemon's own pid is unresolvable")
            return
        }
        guard let samples = await AmxBackend.attachProcessSamples(forPIDs: candidates) else {
            log.error("orphan attach GC aborted: process confirm query unavailable")
            return
        }
        // Profile fence (INT-914): every fence above is process-local, so a
        // SISTER profile's daemon matches them all (same binary name, same
        // `attach <uuid>` argv, ppid == 1 after its app relaunched and its
        // old clients died). What cannot cross profiles is where the session's
        // socket lives: only sessions with a live socket in THIS profile's
        // directory are this sweep's to reap. Computed fresh like the
        // list/snapshot above; a stat failure reads as foreign — spared.
        let localSessionSockets = Set(
            samples.compactMap(\.sessionArgument).filter {
                DaemonGCPlan.isUUIDShaped($0)
                    && sessionSocketExists(named: $0, in: AmxBackend.sessionSocketDirectory())
            }
        )
        let foreignCandidates = samples.filter {
            $0.sessionArgument.map { DaemonGCPlan.isUUIDShaped($0) && !localSessionSockets.contains($0) }
                ?? false
        }.count
        if foreignCandidates > 0 {
            log.info(
                "orphan attach GC: sparing \(foreignCandidates) candidate(s) with no session socket in this profile's directory"
            )
        }
        let confirmed = DaemonGCPlan.confirmedOrphanAttachSamples(
            samples: samples, daemonPIDs: freshDaemonPIDs, executableName: AmxBackend.executableName,
            localSessionSockets: localSessionSockets
        )
        guard !confirmed.isEmpty else { return }

        let signaled = await signalConfirmedOrphanAttachClients(confirmed)
        log.info("daemon GC: signaled \(signaled)/\(confirmed.count) orphan attach client(s)")
    }

    /// Revalidates both liveness and the complete sampled process identity at
    /// the last responsible moment before each signal. Keeping the original
    /// sample closes the pid-reuse gaps after discovery and during the TERM
    /// grace without weakening the existing fail-closed process query.
    nonisolated static func signalConfirmedOrphanAttachClients(
        _ confirmed: [DaemonGCPlan.AttachProcessSample],
        sampleProcesses: @escaping @Sendable ([Int32]) async -> [DaemonGCPlan.AttachProcessSample]? = {
            await AmxBackend.attachProcessSamples(forPIDs: $0)
        },
        processExists: @escaping @Sendable (Int32) -> Bool = { Darwin.kill($0, 0) == 0 },
        signalProcess: @escaping @Sendable (Int32, Int32) async -> Int32 = { Darwin.kill($0, $1) },
        waitForGrace: @escaping @Sendable (Duration) async -> Void = {
            try? await ContinuousClock().sleep(for: $0)
        }
    ) async -> Int {
        var terminated: [DaemonGCPlan.AttachProcessSample] = []
        for expected in confirmed {
            guard processExists(expected.pid),
                let samples = await sampleProcesses([expected.pid]),
                let current = samples.first(where: { $0.pid == expected.pid }),
                DaemonGCPlan.isSameAttachProcess(current, as: expected)
            else { continue }
            guard await signalProcess(expected.pid, SIGTERM) == 0 else {
                let errnoValue = errno
                log.error("orphan attach signal failed for pid=\(expected.pid): errno=\(errnoValue)")
                continue
            }
            terminated.append(expected)
        }

        guard !terminated.isEmpty else { return 0 }
        await waitForGrace(.seconds(1))
        for expected in terminated {
            guard processExists(expected.pid),
                let samples = await sampleProcesses([expected.pid]),
                let current = samples.first(where: { $0.pid == expected.pid }),
                DaemonGCPlan.isSameAttachProcess(current, as: expected)
            else { continue }
            _ = await signalProcess(expected.pid, SIGKILL)
        }
        return terminated.count
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
        guard let candidates = candidateFiles(in: directory, matching: { $0.hasSuffix(".status.jsonl") })
        else {
            // A failed scan must not masquerade as "spared 0": skip the metric.
            log.error("status-file GC skipped: directory scan unavailable")
            return
        }
        // Restore-attach race measurement (issue #184, "measure first"): every
        // sweep, log the upper bound on stale generations the `attached` gate is
        // sparing — emitted INCLUDING zero so a run of zeros is a real
        // observation, not an absent/ambiguous line. No behavior change.
        let spared = DaemonGCPlan.attachGateSparedStatusFiles(
            candidates: candidates, attached: attached, gcStart: gcStart
        )
        log.info(
            "status-file GC: attach gate spared \(spared.files) stale-eligible status file(s) across \(spared.sessions) session(s) — upper bound on restore-attach race leakage"
        )
        let stale = DaemonGCPlan.staleStatusFiles(
            candidates: candidates,
            attached: attached,
            gcStart: gcStart
        )
        unlinkStale(stale, in: directory, kind: "status file")
    }

    /// Removes leaked per-session `<uuid>.log[.old]` files under
    /// `$TMPDIR/amx/logs/` — anything whose session has no live daemon, is past
    /// the grace window, and is attributable to a minted session
    /// (Interactive-Buffoonery/awesomux#184). Decision logic lives in
    /// `DaemonGCPlan.staleSessionLogs`; this is the IO. `live` is nil when the
    /// session list failed OR parsed non-strictly — both abort. Spares on any
    /// LIVE daemon (not just attached, since a detached-but-live daemon still
    /// holds the log fd) and on any `owned` id (restore can recreate that
    /// session's daemon and reopen the same log path mid-sweep). The logs
    /// directory is often absent (no daemon has logged) — a nil scan is that
    /// normal case, so return quietly rather than logging an error.
    nonisolated static func sweepSessionLogs(
        live: [LiveDaemon]?,
        owned: Set<TerminalSessionID>,
        gcStart: Int,
        directory: String = AmxBackend.sessionLogDirectory()
    ) {
        guard let live else {
            log.error("log GC skipped: session list unavailable or unparseable")
            return
        }
        guard
            let candidates = candidateFiles(
                in: directory,
                matching: {
                    $0.hasSuffix(".log") || $0.hasSuffix(".log.old")
                })
        else { return }
        let stale = DaemonGCPlan.staleSessionLogs(
            candidates: candidates,
            liveSessionIDs: Set(live.map(\.id)),
            owned: owned,
            gcStart: gcStart
        )
        unlinkStale(stale, in: directory, kind: "log file")
    }

    /// Whether `directory/name` is a unix-socket filesystem entry — the
    /// INT-914 ownership test for orphan-attach GC. `lstat` (not `stat`) and
    /// a strict S_IFSOCK type check: an absent entry, a squatting regular
    /// file, or a symlink all read as NOT ours, which spares the candidate
    /// rather than authenticating a cross-profile kill.
    ///
    /// Deliberately an EXISTENCE test, never a liveness probe: only this
    /// profile's daemons ever create entries here, so even an entry left by a
    /// SIGKILLed daemon (no unlink on the way out) proves the targeted session
    /// belonged to this profile — and its orphaned attach client is exactly
    /// who this sweep exists to reap. Requiring a connectable listener instead
    /// would spare those crashes' clients forever, and against a same-user
    /// squatter a liveness check buys nothing (`bind()` costs no more than
    /// creating a dead socket). Only ever called with UUID-shaped names (no
    /// path traversal) from `reapOrphanAttachClients`.
    nonisolated static func sessionSocketExists(named name: String, in directory: String) -> Bool {
        var status = stat()
        guard lstat(directory + "/" + name, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Enumerates `directory` and returns regular files whose name matches
    /// `predicate`, paired with mtime. Resource values come from the same
    /// enumeration pass (one stat per entry) and do not follow symlinks;
    /// requiring a regular file keeps a directory or symlink squatting a
    /// matching name out of candidacy. Returns nil when the directory cannot be
    /// enumerated (absent or IO error) — distinct from an empty result — so the
    /// caller can tell "scan failed" from "scanned, found nothing" (the
    /// restore-race metric must not report a false zero on a failed scan).
    // ponytail: blocking FileManager IO on the cooperative pool — launch-once,
    // .utility, O(directory entries); hop to a DispatchQueue if the launch
    // scan ever stalls.
    nonisolated private static func candidateFiles(
        in directory: String,
        matching predicate: (String) -> Bool
    ) -> [DaemonGCPlan.FileCandidate]? {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: []
            )
        else { return nil }
        return entries.compactMap { url -> DaemonGCPlan.FileCandidate? in
            // A per-entry stat failure (file vanished mid-scan, permissions)
            // drops just that entry from both the sweep and the race metric —
            // benign and caught next launch. Deliberately NOT an abort: one
            // disappearing file must not cancel the whole sweep's deletions.
            guard predicate(url.lastPathComponent),
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { return nil }
            return DaemonGCPlan.FileCandidate(
                filename: url.lastPathComponent,
                modifiedEpoch: Int(modified.timeIntervalSince1970)
            )
        }
    }

    /// Unlinks the planned stale files by name under `directory`. `kind` labels
    /// the summary/error logs. Shared by the status and log sweeps.
    nonisolated private static func unlinkStale(
        _ stale: [String],
        in directory: String,
        kind: String
    ) {
        guard !stale.isEmpty else { return }
        var removed = 0
        for name in stale {
            // unlink(2), not FileManager.removeItem: refuses directories at
            // the syscall even if the entry changed type after the check
            // above, and unlinks a symlink itself rather than its target.
            if Darwin.unlink(directory + "/" + name) == 0 {
                removed += 1
            } else if errno != ENOENT {
                // ENOENT is the benign race: the file's own owner removed it
                // first — the desired end state, not an error.
                let errnoValue = errno
                log.error(
                    "\(kind, privacy: .public) GC unlink failed for \(name, privacy: .public): errno=\(errnoValue)"
                )
            }
        }
        log.info("daemon GC: removed \(removed)/\(stale.count) stale \(kind, privacy: .public)(s)")
    }
}
