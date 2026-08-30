#if os(Linux)
    import Foundation
    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #endif

    public struct LinuxProcessSnapshotReader: Sendable {
        private let procURL: URL

        public init(procPath: String = "/proc") {
            procURL = URL(fileURLWithPath: procPath, isDirectory: true)
        }

        public func read(sessionID: String) -> ProcessTableSnapshot {
            let fileManager = FileManager.default
            let currentUID = geteuid()
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: procURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                return ProcessTableSnapshot(processes: [], markerSeenButUnreadable: true)
            }

            var processes: [ProcessSnapshot] = []
            var markerSeenButUnreadable = false
            for entry in entries {
                guard let pid = Int32(entry.lastPathComponent), pid > 0 else { continue }
                var metadata = stat()
                guard lstat(entry.path, &metadata) == 0, metadata.st_uid == currentUID else {
                    continue
                }

                let statPath = entry.appendingPathComponent("stat").path
                let environPath = entry.appendingPathComponent("environ").path
                guard let firstStat = Self.readStat(path: statPath, pid: pid) else { continue }
                guard let environment = try? Data(contentsOf: URL(fileURLWithPath: environPath)) else {
                    continue
                }
                let marked = Self.environment(environment, containsSessionID: sessionID)
                guard let secondStat = Self.readStat(path: statPath, pid: pid),
                    firstStat.startTime == secondStat.startTime
                else {
                    if marked { markerSeenButUnreadable = true }
                    continue
                }
                processes.append(secondStat.withMarker(marked))
            }
            return ProcessTableSnapshot(
                processes: processes,
                markerSeenButUnreadable: markerSeenButUnreadable
            )
        }

        private static func environment(_ data: Data, containsSessionID sessionID: String) -> Bool {
            let expected = Data("AWESOMUX_BRIDGE_SESSION=\(sessionID)".utf8)
            return data.split(separator: 0).contains { Data($0) == expected }
        }

        private static func readStat(path: String, pid: Int32) -> ProcessSnapshot? {
            guard let line = try? String(contentsOfFile: path, encoding: .utf8),
                let open = line.firstIndex(of: "("),
                let close = line.lastIndex(of: ")"),
                open < close
            else {
                return nil
            }
            let command = String(line[line.index(after: open)..<close])
            let fields = line[line.index(after: close)...].split(separator: " ")
            guard fields.count > 19,
                let state = fields[0].first,
                let parentPID = Int32(fields[1]),
                let processGroupID = Int32(fields[2]),
                let processSessionID = Int32(fields[3]),
                let controllingTerminal = Int64(fields[4]),
                let foregroundProcessGroupID = Int32(fields[5]),
                let startTime = UInt64(fields[19])
            else {
                return nil
            }
            return ProcessSnapshot(
                pid: pid,
                parentPID: parentPID,
                processGroupID: processGroupID,
                processSessionID: processSessionID,
                controllingTerminal: controllingTerminal,
                foregroundProcessGroupID: foregroundProcessGroupID,
                state: state,
                command: command,
                startTime: startTime,
                hasSessionMarker: false
            )
        }
    }
#endif
