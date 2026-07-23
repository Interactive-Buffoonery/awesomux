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
                if byte != 0x2d { return false }      // '-'
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
                  !seen.contains(name) else { continue }
            // Fail safe: if `clients` is absent/unparseable we cannot prove the
            // daemon is unattached, so default to 1 (in use) and spare it.
            let clients = fields["clients"].flatMap(Int.init) ?? 1
            seen.insert(name)
            result.append(LiveDaemon(id: id, pid: pid, createdEpoch: created, clients: clients))
        }
        return result
    }

    public static func parseProcessSnapshot(_ raw: String) -> [ProcEntry] {
        var result: [ProcEntry] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
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
                return false            // exec'd over the shell — live work
            }
            if snapshot.contains(where: { $0.ppid == child.pid }) {
                return false            // shell is running a foreground command
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
                  now - daemon.createdEpoch >= cap else { continue }
            seen.insert(daemon.id)
            result.append(daemon)
        }
        return result
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
                  daemon.clients == 0,            // never reap a daemon in active use
                  !owned.contains(daemon.id),
                  !busy.contains(daemon.id),
                  daemon.createdEpoch < gcStart else { continue }
            seen.insert(daemon.id)
            result.append(daemon)
        }
        return result
    }

}
