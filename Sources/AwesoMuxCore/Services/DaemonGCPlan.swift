import AwesoMuxBridgeProtocol
import Foundation

/// Pure decision logic for launch-time orphan daemon GC (INT-570 / ADR-0011).
/// Lives in Core so the whole correctness matrix is unit-testable; `AmxBackend`
/// supplies the `amx`/`ps` text this consumes.
public enum DaemonGCPlan {
    /// awesoMux mints `TerminalSessionID.generate()` = lowercased UUID. Only
    /// these are GC candidates, so a hand-run `amx attach dev` is never killed.
    public static func isUUIDShaped(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 36 else { return false }
        func isHex(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x61...0x66).contains(b) }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != 0x2d { return false }  // '-'
            } else if !isHex(byte) {
                return false
            }
        }
        return true
    }

    public static func parseAmxList(_ raw: String) -> [LiveDaemon] {
        var result: [LiveDaemon] = []
        var seen = Set<String>()
        for line in raw.split(whereSeparator: \.isNewline) {
            var fields: [String: String] = [:]
            for token in line.split(separator: "\t") {
                guard let eq = token.firstIndex(of: "=") else { continue }
                // `amx list` indents each line ("  name=…"), so trim the key.
                let key = token[..<eq].trimmingCharacters(in: .whitespaces)
                fields[key] = String(token[token.index(after: eq)...])
            }
            guard let name = fields["name"]?.trimmingCharacters(in: .whitespaces),
                let id = TerminalSessionID(rawValue: name),
                let pidString = fields["pid"], let pid = Int32(pidString),
                let createdString = fields["created"], let created = Int(createdString),
                !seen.contains(name)
            else { continue }
            // Fail safe: if `clients` is absent/unparseable we cannot prove the
            // daemon is unattached, so default to 1 (in use) and spare it.
            let clients = fields["clients"].flatMap(Int.init) ?? 1
            seen.insert(name)
            result.append(LiveDaemon(id: id, pid: pid, createdEpoch: created, clients: clients))
        }
        return result
    }

    /// All-or-nothing variant of `parseAmxList` for destructive consumers:
    /// nil unless every nonblank line yields a distinct daemon. The tolerant
    /// parser's skip-what-you-can't-read is fail-safe for the daemon reaper
    /// (an unparsed row just isn't killed) but fail-DANGEROUS for the
    /// status-file sweep, where a dropped live row reads as "no daemon →
    /// stale file → delete". Format drift must abort the sweep instead.
    public static func parseAmxListStrict(_ raw: String) -> [LiveDaemon]? {
        let nonblankLines = raw.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let parsed = parseAmxList(raw)
        return parsed.count == nonblankLines.count ? parsed : nil
    }

    public static func parseProcessSnapshot(_ raw: String) -> [ProcEntry] {
        var result: [ProcEntry] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                let pid = Int32(parts[0]), let ppid = Int32(parts[1])
            else { continue }
            let command = parts[2...].joined(separator: " ")
            result.append(ProcEntry(pid: pid, ppid: ppid, command: command))
        }
        return result
    }

    /// Idle iff every direct child of the daemon is a recognized login shell
    /// with no children of its own. Zero children counts as idle (nothing runs).
    ///
    /// Ceiling: this is process-tree evidence, not prompt state. A shell busy in
    /// a builtin / function / `read` loop with no child process reads as idle.
    /// Acceptable for v1 because reaping also requires `clients == 0` (detached)
    /// and the bridge ships off; upgrade path is an `amx`-sourced prompt/idle
    /// signal (shared with the INT-217 QuitRiskPolicy work).
    public static func isIdle(daemonPID: Int32, in snapshot: [ProcEntry]) -> Bool {
        let children = snapshot.filter { $0.ppid == daemonPID }
        for child in children {
            guard ShellRecognition.isRecognizedShell(child.command) else {
                return false  // exec'd over the shell — live work
            }
            if snapshot.contains(where: { $0.ppid == child.pid }) {
                return false  // shell is running a foreground command
            }
        }
        return true
    }

    /// Splits reachable ids by *how* they're reachable: a live workspace pane
    /// (`livePane`) vs only a reopen / recently-closed entry (`restorable`). The
    /// two sets are disjoint — a live id is removed from `restorable` — so the
    /// session-manager surface can show `owned` distinctly from `detachedRestorable`.
    public static func reachability(
        groups: [SessionGroup],
        recentlyClosed: [RecentlyClosedWorkspace],
        lastClosedTransient: RecentlyClosedWorkspace?
    ) -> (livePane: Set<TerminalSessionID>, restorable: Set<TerminalSessionID>) {
        var livePane = Set<TerminalSessionID>()
        for group in groups {
            for session in group.sessions {
                session.layout.forEachPane { livePane.insert($0.terminalSessionID) }
            }
        }
        var restorable = Set<TerminalSessionID>()
        for closed in recentlyClosed {
            closed.layout.forEachPane { restorable.insert($0.terminalSessionID) }
        }
        lastClosedTransient?.layout.forEachPane { restorable.insert($0.terminalSessionID) }
        return (livePane, restorable.subtracting(livePane))
    }

    public static func reachableSessionIDs(
        groups: [SessionGroup],
        recentlyClosed: [RecentlyClosedWorkspace],
        lastClosedTransient: RecentlyClosedWorkspace?
    ) -> Set<TerminalSessionID> {
        let r = reachability(groups: groups, recentlyClosed: recentlyClosed, lastClosedTransient: lastClosedTransient)
        return r.livePane.union(r.restorable)
    }

    /// Launch-GC extension for the opt-in idle/age cap (INT-573). Reaps orphan
    /// daemons that have aged past the cap and are still idle + unattached +
    /// unpinned. Shares the orphan fences with `reapable` (UUID-shape, clients==0,
    /// not owned/busy, created < gcStart); pinning is the "forever" exemption.
    public static func expiredReapable(
        live: [LiveDaemon],
        owned: Set<TerminalSessionID>,
        busy: Set<TerminalSessionID>,
        pinned: Set<TerminalSessionID>,
        idleByID: [TerminalSessionID: Bool],
        capThresholdSeconds: Int?,
        now: Int,
        gcStart: Int
    ) -> [LiveDaemon] {
        guard let cap = capThresholdSeconds else { return [] }
        var result: [LiveDaemon] = []
        var seen = Set<TerminalSessionID>()
        for daemon in live where !seen.contains(daemon.id) {
            guard isUUIDShaped(daemon.id.rawValue),
                daemon.clients == 0,
                !owned.contains(daemon.id),
                !busy.contains(daemon.id),
                !pinned.contains(daemon.id),
                idleByID[daemon.id] == true,
                daemon.createdEpoch < gcStart,
                now - daemon.createdEpoch >= cap
            else { continue }
            seen.insert(daemon.id)
            result.append(daemon)
        }
        return result
    }

    /// A file observed in an amx directory, as input to a stale-file sweep
    /// (`staleStatusFiles` for `$TMPDIR/amx/*.status.jsonl`, `staleSessionLogs`
    /// for `$TMPDIR/amx/logs/<uuid>.log[.old]`). `modifiedEpoch` is the mtime.
    public struct FileCandidate: Equatable {
        public let filename: String
        public let modifiedEpoch: Int

        public init(filename: String, modifiedEpoch: Int) {
            self.filename = filename
            self.modifiedEpoch = modifiedEpoch
        }
    }

    /// Session id embedded in a per-attach status filename
    /// (`<lowercase-uuid>-<8 lowercase hex>.status.jsonl`, minted by
    /// `AmxBackend.makeStatusChannel`), or nil for anything else. Strict on
    /// purpose: GC must never delete a file it cannot positively attribute
    /// to a minted session. Deliberate scope ceiling: hand-named sessions
    /// (`amx attach dev`) also mint status files but are never candidates —
    /// same sparing rule as the daemon reaper's `isUUIDShaped` gate. Their
    /// volume is dev-only; widen only with a name-set cross-check. A
    /// same-UID process can also squat `<live-uuid>-<any hex>` to keep its
    /// own junk file spared — nuisance only, it already has full
    /// same-user filesystem access.
    public static func statusFileSessionID(_ filename: String) -> TerminalSessionID? {
        let suffix = ".status.jsonl"
        guard filename.hasSuffix(suffix) else { return nil }
        let stem = filename.dropLast(suffix.count)
        guard stem.count == 45 else { return nil }  // uuid(36) + "-" + token(8)
        let uuid = String(stem.prefix(36))
        let separatorIndex = stem.index(stem.startIndex, offsetBy: 36)
        let token = stem[stem.index(after: separatorIndex)...]
        func isLowercaseHex(_ c: Character) -> Bool {
            ("0"..."9").contains(c) || ("a"..."f").contains(c)
        }
        guard isUUIDShaped(uuid),
            stem[separatorIndex] == "-",
            token.allSatisfy(isLowercaseHex)
        else { return nil }
        return TerminalSessionID(rawValue: uuid)
    }

    /// A status file must be at least this old (relative to sweep start)
    /// before it can be deleted. Another app instance mints its status file
    /// BEFORE `amx attach` registers the daemon — during a slow (remote)
    /// preflight that gap is seconds, and such a session is in neither this
    /// instance's `owned` set nor `amx list` yet. Leaked orphans are hours
    /// to days old, so a wide grace costs nothing: they're gone next launch.
    public static let statusFileGraceSeconds = 3600

    /// Launch-GC sweep for leaked per-attach status files: every attach mints
    /// a fresh file and only a clean `AmxStatusFileWatcher.stop()` removes it,
    /// so crashes and force-kills accumulate orphans forever — mostly as
    /// stale GENERATIONS of sessions that are still alive, so sparing by
    /// session id would keep the actual backlog forever.
    ///
    /// A file is deletable unless one of three things protects it:
    /// - its session has an attached client (`attached`, from `amx list`
    ///   `clients > 0`): an active status channel can only belong to an
    ///   attach process, and a quiet long-lived attach's file mtime can be
    ///   arbitrarily old, so attachment — not recency — is the discriminator
    ///   for "current channel". One session can hold several simultaneously
    ///   active channels (pop-up mirror), which is why no newest-N heuristic
    ///   is safe here.
    /// - it is inside the grace window (covers an in-flight attach whose
    ///   daemon/client is not visible in `amx list` yet — including another
    ///   app instance's).
    /// - its name cannot be positively attributed to a minted session.
    ///
    /// Sessions whose only clients are leaked orphan attach processes
    /// (Interactive-Buffoonery/awesomux#183) are spared too — the safe
    /// direction; their files become collectable once #183 reaps orphans.
    public static func staleStatusFiles(
        candidates: [FileCandidate],
        attached: Set<TerminalSessionID>,
        gcStart: Int,
        graceSeconds: Int = statusFileGraceSeconds
    ) -> [String] {
        candidates.compactMap { candidate in
            guard let id = statusFileSessionID(candidate.filename),
                !attached.contains(id),
                candidate.modifiedEpoch < gcStart - graceSeconds
            else { return nil }
            return candidate.filename
        }
    }

    /// Session id embedded in a per-session log filename under
    /// `$TMPDIR/amx/logs/`. zmx writes `<session_name>.log` and rotates it to
    /// `<session_name>.log.old` at 5 MB (`LogSystem.rotate`), so BOTH shapes
    /// are attributable to the same session. awesoMux session names are minted
    /// lowercase UUIDs, so this returns the id only for `<uuid>.log[.old]`.
    /// Same strict-attribution ceiling as `statusFileSessionID`: the global
    /// `zmx.log` (non-UUID stem) and hand-named sessions are never candidates,
    /// so GC only ever deletes a log it can positively attribute to a minted
    /// session. `.log.old` naturally sorts against the same id, keeping a
    /// rotated dead session's pair reclaimed together.
    public static func logFileSessionID(_ filename: String) -> TerminalSessionID? {
        let stem: Substring
        if filename.hasSuffix(".log") {
            stem = filename.dropLast(4)
        } else if filename.hasSuffix(".log.old") {
            stem = filename.dropLast(8)
        } else {
            return nil
        }
        guard stem.count == 36, isUUIDShaped(String(stem)) else { return nil }
        return TerminalSessionID(rawValue: String(stem))
    }

    /// Launch-GC sweep for leaked per-session log files: zmx opens the log at
    /// daemon spawn and only a dead session's file lingers, so orphans pile up
    /// forever (37 observed, Interactive-Buffoonery/awesomux#184).
    ///
    /// Unlike status files (one per attach, so `attached` is the discriminator),
    /// there is exactly one live log — plus at most one rotated `.old` — per
    /// session NAME. So a log is spared unless one of three things protects it:
    /// - its session has a LIVE daemon (`liveSessionIDs`, any client count).
    ///   The current `<uuid>.log` is held open by the daemon (any client
    ///   count) and actively written; its rotated `<uuid>.log.old` is a closed
    ///   file (zmx closes it before renaming, `LogSystem.rotate`) but is
    ///   retained as bounded diagnostic history — at most one per session,
    ///   reclaimed with the current log once the session dies. Sparing it does
    ///   not affect rotation: zmx's `rename(2)` replaces any existing `.old`.
    /// - it is inside the grace window. Log-specific rationale (do NOT reuse the
    ///   status file's): the daemon creates the log at spawn, at the same moment
    ///   it registers in `amx list`, so the gap is near-zero. Grace only covers
    ///   a slow launch where we observe the file a beat before the daemon shows
    ///   up in the list snapshot.
    /// - its name cannot be positively attributed to a minted session.
    ///
    /// Residual (accepted): a daemon RECREATED after the `amx list` snapshot but
    /// before unlink reopens the same path and seeks to end (`LogSystem.init`);
    /// this sweep can unlink its just-reopened log, and it keeps writing to the
    /// unlinked inode until next launch. This is diagnostic-log loss, not data
    /// loss, and the window is narrow (grace + any write refreshing mtime spares
    /// it), so it is not fenced with a pre-unlink revalidation.
    public static func staleSessionLogs(
        candidates: [FileCandidate],
        liveSessionIDs: Set<TerminalSessionID>,
        gcStart: Int,
        graceSeconds: Int = statusFileGraceSeconds
    ) -> [String] {
        candidates.compactMap { candidate in
            guard let id = logFileSessionID(candidate.filename),
                !liveSessionIDs.contains(id),
                candidate.modifiedEpoch < gcStart - graceSeconds
            else { return nil }
            return candidate.filename
        }
    }

    /// Instrumentation for the restore-attach race
    /// (Interactive-Buffoonery/awesomux#184): the status files that would be
    /// deleted RIGHT NOW if their session were not attached — attributable,
    /// past the grace window, and spared solely by the `attached` gate — plus
    /// how many distinct sessions they span. This is the direct measure of what
    /// the attach gate keeps alive. It is still an UPPER BOUND on leaked stale
    /// generations: a session's legitimately-current channel that happens to
    /// have an old mtime also counts, and a session can hold several
    /// simultaneous live channels (pop-up mirror) — which is exactly why no
    /// newest-N reclamation is safe. "Measure first" (issue): the caller emits
    /// this every sweep INCLUDING zero, so a run of zeros is a real observation
    /// (the race is not losing) rather than an absent, ambiguous log line.
    public static func attachGateSparedStatusFiles(
        candidates: [FileCandidate],
        attached: Set<TerminalSessionID>,
        gcStart: Int,
        graceSeconds: Int = statusFileGraceSeconds
    ) -> (files: Int, sessions: Int) {
        var sessions = Set<TerminalSessionID>()
        var files = 0
        for candidate in candidates {
            guard let id = statusFileSessionID(candidate.filename),
                attached.contains(id),
                candidate.modifiedEpoch < gcStart - graceSeconds
            else { continue }
            files += 1
            sessions.insert(id)
        }
        return (files, sessions.count)
    }

    public static func reapable(
        live: [LiveDaemon],
        owned: Set<TerminalSessionID>,
        busy: Set<TerminalSessionID>,
        gcStart: Int
    ) -> [LiveDaemon] {
        var result: [LiveDaemon] = []
        var seen = Set<TerminalSessionID>()
        for daemon in live where !seen.contains(daemon.id) {
            guard isUUIDShaped(daemon.id.rawValue),
                daemon.clients == 0,  // never reap a daemon in active use
                !owned.contains(daemon.id),
                !busy.contains(daemon.id),
                daemon.createdEpoch < gcStart
            else { continue }
            seen.insert(daemon.id)
            result.append(daemon)
        }
        return result
    }

}
