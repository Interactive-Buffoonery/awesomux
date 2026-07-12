import Darwin
import Foundation

/// Thin libproc wrapper for quit-risk sampling: the foreground process name and
/// whether a pid has live children. No subprocess (`ps`) — these are direct
/// syscalls, fast enough to run synchronously on the quit gate. Returns nil when
/// a fact cannot be resolved so the caller classifies it as indeterminate rather
/// than silently idle.
enum ProcessLivenessProbe {
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

    /// Whether `pid` has at least one child process, or nil if the child list
    /// cannot be resolved. Uses `proc_listpids(PROC_PPID_ONLY, …)`. Returns nil
    /// (not false) when the pid is gone — the sizing call may return a non-zero
    /// count for a dead pid, but the write call returns 0; both zero-count paths
    /// revalidate existence so a vanished parent yields nil (indeterminate) rather
    /// than false (idle-safe).
    static func hasChildren(pid: pid_t) -> Bool? {
        guard pid > 0 else { return nil }
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard needed >= 0 else { return nil }
        if needed == 0 {
            // proc_listpids returns 0 for BOTH "live parent, no children" AND
            // "parent already gone" — revalidate so a parent that exited in the
            // sampling window reports nil (indeterminate → warn), not idle.
            return processExists(pid: pid) ? false : nil
        }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let written = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, needed)
        guard written >= 0 else { return nil }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        if count == 0 {
            // Second call returned 0: the pid vanished between the sizing and
            // write calls (TOCTOU). Same ambiguity as needed==0; revalidate.
            return processExists(pid: pid) ? false : nil
        }
        return pids.prefix(count).contains { $0 > 0 }
    }

    /// kill(pid, 0): 0 = exists; EPERM = exists but unsignalable; ESRCH = gone.
    private static func processExists(pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
