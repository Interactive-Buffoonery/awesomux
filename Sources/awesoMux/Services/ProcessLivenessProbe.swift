import AwesoMuxCore
import Darwin
import Foundation
import OSLog

/// Thin libproc wrapper for quit-risk sampling: the foreground process name and
/// whether a pid has live children. No subprocess (`ps`) — these are direct
/// syscalls, fast enough to run synchronously on the quit gate. Returns nil when
/// a fact cannot be resolved so the caller classifies it as indeterminate rather
/// than silently idle.
enum ProcessLivenessProbe {
    enum ForegroundExecutableMatch: Equatable, Sendable {
        case matching
        case notMatching
        case unknown
    }

    /// The process name (`p_comm`) for `pid`, or nil if it cannot be read
    /// (dead/reaped pid, or a permission error).
    static func foregroundComm(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // The pointer overload of String(cString:) (vs the deprecated [CChar]
        // array overload) reads the null-terminated p_comm buffer. baseAddress
        // is non-nil here — `buffer` is a fixed-size, non-empty array.
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The process start time in MICROSECONDS since epoch for `pid`, or nil if
    /// it cannot be read (dead/reaped pid, or a permission error). Paired with
    /// `pid` this is a foreground-process "incarnation" — see
    /// `AgentForegroundIncarnation` — cheap enough to call at nudge-verify
    /// time: one extra `proc_pidinfo` syscall alongside the existing
    /// `foregroundComm` read.
    ///
    /// Microsecond (not second) resolution is load-bearing, not cosmetic: a
    /// PID recycled by the OS within the same wall-clock second would
    /// otherwise compare equal to a stale incarnation at second precision —
    /// `proc_bsdinfo` already reports `pbi_start_tvusec` for free, so there is
    /// no reason to discard it (review finding).
    static func processStartTime(pid: pid_t) -> Int? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Int(info.pbi_start_tvsec) * 1_000_000 + Int(info.pbi_start_tvusec)
    }

    /// Whether `pid` has at least one child process, or nil if the child list
    /// cannot be resolved. Uses `proc_listpids(PROC_PPID_ONLY, …)`. Returns nil
    /// (not false) when the pid is gone — the sizing call may return a non-zero
    /// count for a dead pid, but the write call returns 0; both zero-count paths
    /// revalidate existence so a vanished parent yields nil (indeterminate) rather
    /// than false (idle-safe).
    static func hasChildren(pid: pid_t) -> Bool? {
        childPIDs(pid: pid).map { !$0.isEmpty }
    }

    /// The foreground process group of `pid`'s controlling terminal
    /// (`kinfo_proc.kp_eproc.e_tpgid`), or nil when the pid is gone, has no
    /// controlling terminal, or that terminal has no foreground group. For a
    /// bridged session root shell this is the daemon PTY's foreground group —
    /// the same fact `tcgetpgrp` reports daemon-side — so a background or
    /// stale descendant (e.g. ssh) is never mistaken for the foreground owner.
    static func terminalForegroundProcessGroup(pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
            size == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        let tpgid = info.kp_eproc.e_tpgid
        return tpgid > 0 ? tpgid : nil
    }

    /// INT-569 field diagnostics: names which guard denied foreground evidence
    /// so a real-machine "Couldn't verify a local terminal" report is
    /// attributable from `log show` without a debugger. Pids/counts only —
    /// never process names or command lines.
    nonisolated private static let nudgeProbeLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "DocumentNudgeGate"
    )

    static func terminalForegroundComm(
        daemonPID: pid_t,
        childPIDs: (pid_t) -> [pid_t]? = { ProcessLivenessProbe.childPIDs(pid: $0) },
        foregroundGroup: (pid_t) -> pid_t? = {
            ProcessLivenessProbe.terminalForegroundProcessGroup(pid: $0)
        },
        comm: (pid_t) -> String? = { ProcessLivenessProbe.foregroundComm(pid: $0) }
    ) -> String? {
        guard let roots = childPIDs(daemonPID) else {
            nudgeProbeLogger.info(
                "nudge probe: cannot list children of daemon \(daemonPID, privacy: .public)")
            return nil
        }
        guard roots.count == 1 else {
            nudgeProbeLogger.info(
                "nudge probe: daemon \(daemonPID, privacy: .public) has \(roots.count, privacy: .public) children (expected 1)"
            )
            return nil
        }
        guard let processGroup = foregroundGroup(roots[0]) else {
            nudgeProbeLogger.info(
                "nudge probe: no foreground process group for root \(roots[0], privacy: .public)")
            return nil
        }
        guard let observed = comm(processGroup) else {
            nudgeProbeLogger.info(
                "nudge probe: comm read failed for pgid \(processGroup, privacy: .public)")
            return nil
        }
        return observed
    }

    /// The pid of the foreground process itself (leader of the bridged
    /// daemon's sole root shell's foreground process group), or nil when
    /// unresolvable. Same traversal as `terminalForegroundComm` — kept as a
    /// separate function (not a refactor of it) so its existing injected-
    /// closure test coverage is untouched.
    ///
    /// This is the pid the document-nudge generation check must bind to for a
    /// bridged pane: the DAEMON's own incarnation (`respawnLedger.lastIncarnation`)
    /// survives a same-daemon CLI relaunch (a persistent bridged session's
    /// user quits and restarts the agent CLI inside the same shell), so
    /// keying on the daemon alone would silently re-trust a fresh, unverified
    /// CLI process — the exact spoof window this gate exists to close.
    static func terminalForegroundPID(
        daemonPID: pid_t,
        childPIDs: (pid_t) -> [pid_t]? = { ProcessLivenessProbe.childPIDs(pid: $0) },
        foregroundGroup: (pid_t) -> pid_t? = {
            ProcessLivenessProbe.terminalForegroundProcessGroup(pid: $0)
        }
    ) -> pid_t? {
        guard let roots = childPIDs(daemonPID), roots.count == 1 else {
            return nil
        }
        return foregroundGroup(roots[0])
    }

    static func terminalForegroundExecutableMatch(
        _ executable: String,
        daemonPID: pid_t,
        foregroundComm: (pid_t) -> String? = {
            ProcessLivenessProbe.terminalForegroundComm(daemonPID: $0)
        }
    ) -> ForegroundExecutableMatch {
        guard let observed = foregroundComm(daemonPID) else { return .unknown }
        return observed == executable ? .matching : .notMatching
    }

    static func bridgedLiveness(
        daemonPID: pid_t,
        childPIDs: (pid_t) -> [pid_t]? = { ProcessLivenessProbe.childPIDs(pid: $0) },
        comm: (pid_t) -> String? = { ProcessLivenessProbe.foregroundComm(pid: $0) }
    ) -> ForegroundProcessLiveness {
        guard let daemonChildren = childPIDs(daemonPID) else { return .bridgedBusy }
        for childPID in daemonChildren {
            guard let childComm = comm(childPID), let children = childPIDs(childPID) else {
                return .bridgedBusy
            }
            guard
                ForegroundProcessLiveness.classifyBridged(
                    rootComm: childComm,
                    rootHasChildren: !children.isEmpty
                ) == .bridged
            else { return .bridgedBusy }
        }
        return .bridged
    }

    private static func childPIDs(pid: pid_t) -> [pid_t]? {
        guard pid > 0 else { return nil }
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard needed >= 0 else { return nil }
        if needed == 0 {
            // proc_listpids returns 0 for BOTH "live parent, no children" AND
            // "parent already gone" — revalidate so a parent that exited in the
            // sampling window reports nil (indeterminate → warn), not idle.
            return processExists(pid: pid) ? [] : nil
        }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let written = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, needed)
        guard written >= 0 else { return nil }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        if count == 0 {
            // Second call returned 0: the pid vanished between the sizing and
            // write calls (TOCTOU). Same ambiguity as needed==0; revalidate.
            return processExists(pid: pid) ? [] : nil
        }
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// kill(pid, 0): 0 = exists; EPERM = exists but unsignalable; ESRCH = gone.
    private static func processExists(pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
