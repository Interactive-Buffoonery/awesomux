import Foundation

struct TerminalFileOpenRequest {
    let fileURL: URL
    let workingDirectory: String
    let command: String

    init(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fileURL = url.standardizedFileURL
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
        guard values.isRegularFile == true, values.isExecutable == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        // Reject control characters: a terminal paste must never contain an extra Return.
        guard !fileURL.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.fileURL = fileURL
        workingDirectory = fileURL.deletingLastPathComponent().path
        // Keep backslashes outside single quotes, as in named agent launches, for fish.
        command =
            "'"
            + fileURL.path.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x27: "'\"'\"'"
                case 0x5C: "'\"\\\\\"'"
                default: String(scalar)
                }
            }.joined() + "'"
    }
}
