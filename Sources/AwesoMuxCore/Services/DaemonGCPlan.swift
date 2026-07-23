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

    /// A `*.status.jsonl` file observed in the amx directory, as input to
    /// `staleStatusFiles`. `modifiedEpoch` is the file's mtime.
    public struct StatusFileCandidate: Equatable {
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
        candidates: [StatusFileCandidate],
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

    // MARK: - Orphan attach client GC (Interactive-Buffoonery/awesomux#183)

    /// A crashed/force-killed app leaves its `amx attach <uuid>` child
    /// orphaned to launchd (macOS reparents to pid 1 — verified empirically,
    /// not assumed). That child blocks reading stdin forever with no
    /// timeout, keeping its daemon's `clients` count >= 1 and permanently
    /// defeating `reapable`.
    ///
    /// Cheap first pass over the `ps` snapshot already fetched for busy/idle
    /// classification (no extra IO). Intentionally a shortlist, not a kill
    /// decision: `comm` alone can't distinguish an attach client from the
    /// daemon itself (same binary), so a live daemon pid must still be
    /// excluded via `daemonPIDs`, and `comm` needs basename normalization
    /// because `ps comm=` reports the full executable path for anything
    /// outside `/bin`, `/usr/bin` (e.g. a bundled `.../amx`) — confirmed live
    /// on this machine, not assumed from `/bin/zsh`-shaped test fixtures.
    public static func candidateOrphanAttachPIDs(
        snapshot: [ProcEntry],
        daemonPIDs: Set<Int32>,
        executableName: String
    ) -> [Int32] {
        snapshot.compactMap { entry -> Int32? in
            guard ShellRecognition.basename(entry.command) == executableName,
                entry.ppid == 1,
                !daemonPIDs.contains(entry.pid)
            else { return nil }
            return entry.pid
        }.sorted()
    }

    /// One `ps -p <pids> -o pid=,ppid=,etime=,args=` row for a candidate
    /// pid. `args` is deliberately the LAST `-o` field: BSD `ps` truncates a
    /// text column to a computed width unless it is the final field —
    /// confirmed live (a mid-list `comm=` showed `/usr/libexec/log`,
    /// truncated, while the same field last showed the full
    /// `/usr/libexec/logd`). `etime` stays a safe fixed-width middle field.
    public struct AttachProcessSample: Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let etimeSeconds: Int
        /// `args` split on the first two tokens: argv0 (executable path as
        /// exec'd) and the subcommand (`attach`, `list`, `kill`, ...).
        public let argv0: String
        public let subcommand: String?

        public init(pid: Int32, ppid: Int32, etimeSeconds: Int, argv0: String, subcommand: String?) {
            self.pid = pid
            self.ppid = ppid
            self.etimeSeconds = etimeSeconds
            self.argv0 = argv0
            self.subcommand = subcommand
        }
    }

    /// Parses `ps -p <pids> -o pid=,ppid=,etime=,args=` output. `maxSplits:
    /// 3` keeps `args`' own internal spaces (`amx attach <uuid>`) intact as
    /// the trailing element instead of shredding them.
    public static func parseAttachProcessSamples(_ raw: String) -> [AttachProcessSample] {
        var result: [AttachProcessSample] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                let pid = Int32(parts[0]),
                let ppid = Int32(parts[1]),
                let etime = parseEtimeSeconds(String(parts[2]))
            else { continue }
            let argsTokens = parts[3].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard let argv0 = argsTokens.first else { continue }
            let subcommand = argsTokens.count > 1 ? String(argsTokens[1]) : nil
            result.append(
                AttachProcessSample(
                    pid: pid, ppid: ppid, etimeSeconds: etime,
                    argv0: String(argv0), subcommand: subcommand
                ))
        }
        return result
    }

    /// BSD `ps etime=` is `[[dd-]hh:]mm:ss` (e.g. `05-22:03:16`, `01:23`,
    /// `00:01`). No locale/timezone dependence, unlike `lstart=` — the
    /// reason this field was chosen for the age fence over parsing a
    /// multi-token timestamp.
    static func parseEtimeSeconds(_ etime: String) -> Int? {
        var daysPart = 0
        var clock = etime
        if let dashIndex = etime.firstIndex(of: "-") {
            guard let days = Int(etime[etime.startIndex..<dashIndex]) else { return nil }
            daysPart = days
            clock = String(etime[etime.index(after: dashIndex)...])
        }
        let clockTokens = clock.split(separator: ":")
        let clockParts = clockTokens.compactMap { Int($0) }
        guard clockParts.count == clockTokens.count, !clockParts.isEmpty else { return nil }
        var seconds = 0
        for part in clockParts {
            seconds = seconds * 60 + part
        }
        return daysPart * 86400 + seconds
    }

    /// A leaked orphan is hours-to-days old (issue's own observed data: one
    /// spanned 5 days). A daemon mid-double-fork-daemonize is briefly
    /// `ppid == 1` before it registers in `amx list`, but that transition
    /// completes in milliseconds — this floor is a wide, cheap grace that
    /// cannot mistake a just-starting daemon for a leaked orphan (mirrors
    /// `statusFileGraceSeconds`'s "wide grace costs nothing" reasoning).
    public static let orphanAttachMinAgeSeconds = 60

    /// Second, narrow confirmation pass — run only when the cheap shortlist
    /// above is non-empty. Requires every fence at once: still alive, still
    /// orphaned, still not a daemon, positively an `attach` invocation (not
    /// `list`/`kill`/`send`/`history` — those exit in well under a second and
    /// would never clear `minAgeSeconds` from a genuine same-instance run,
    /// but a foreign/other-instance one-shot orphaned by an unrelated crash
    /// could; the subcommand check removes that ambiguity entirely rather
    /// than relying on timing), and old enough to rule out an in-progress
    /// daemon startup race.
    public static func confirmedOrphanAttachPIDs(
        samples: [AttachProcessSample],
        daemonPIDs: Set<Int32>,
        executableName: String,
        minAgeSeconds: Int = orphanAttachMinAgeSeconds
    ) -> [Int32] {
        samples.compactMap { sample -> Int32? in
            guard sample.ppid == 1,
                ShellRecognition.basename(sample.argv0) == executableName,
                sample.subcommand == "attach",
                !daemonPIDs.contains(sample.pid),
                sample.etimeSeconds >= minAgeSeconds
            else { return nil }
            return sample.pid
        }.sorted()
    }

}
