import Foundation

enum DiagnosticsProcessParser {
    static func parse(_ raw: String) -> [DiagnosticsRawProcess] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                separator: " ",
                maxSplits: 4,
                omittingEmptySubsequences: true
            )
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let cpuPercent = Double(fields[2]),
                  let residentKilobytes = Int64(fields[3]),
                  pid > 0,
                  parentPID >= 0,
                  cpuPercent.isFinite,
                  cpuPercent >= 0,
                  residentKilobytes >= 0 else {
                return nil
            }

            let executablePath = fields[4].trimmingCharacters(in: .whitespaces)
            guard !executablePath.isEmpty, !executablePath.contains("\0") else {
                return nil
            }

            return DiagnosticsRawProcess(
                pid: pid,
                parentPID: parentPID,
                cpuPercent: cpuPercent,
                residentBytes: residentKilobytes * 1_024,
                executablePath: executablePath
            )
        }
    }
}
