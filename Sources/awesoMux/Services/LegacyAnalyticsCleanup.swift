import Foundation

enum LegacyAnalyticsCleanup {
    static func removeData(
        in supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let analyticsDirectory = supportDirectory.appending(
            path: "analytics",
            directoryHint: .isDirectory
        )

        do {
            try fileManager.removeItem(at: analyticsDirectory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
