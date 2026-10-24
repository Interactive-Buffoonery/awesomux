import Darwin
import Foundation

enum CodexHookProcessAncestry {
    static func isSharedAppServer() -> Bool {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1, let process = inspect(pid) else { return false }
            let name = (process.executable as NSString).lastPathComponent
            if name == "codex" || name.hasPrefix("codex-") {
                // Subcommand position only: a TUI's later argv can be a prompt
                // that merely mentions "app-server".
                return process.arguments.dropFirst().first == "app-server"
            }
            pid = process.parentPID
        }
        return false
    }

    private static func inspect(_ pid: pid_t) -> (executable: String, arguments: [String], parentPID: pid_t)? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size, size <= 1024 * 1024
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size, size <= bytes.count
        else { return nil }

        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= size else { return nil }
        var offset = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard offset < size,
                let end = bytes[offset..<size].firstIndex(of: 0),
                let value = String(bytes: bytes[offset..<end], encoding: .utf8)
            else { return nil }
            offset = end + 1
            return value
        }
        guard let executable = readString(), !executable.isEmpty else { return nil }
        // KERN_PROCARGS2 pads between the executable path and argv[0]. Only
        // read argc strings: the environment following argv is not evidence.
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let argument = readString() else { return nil }
            arguments.append(argument)
        }
        return (executable, arguments, pid_t(info.pbi_ppid))
    }
}
