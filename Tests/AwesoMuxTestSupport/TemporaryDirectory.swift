import Foundation

public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    private let fileManager: FileManager

    public init(prefix: String = "awesomux-test", fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        url = fileManager.temporaryDirectory
            .appending(path: prefix + "-" + UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? fileManager.removeItem(at: url)
    }
}
