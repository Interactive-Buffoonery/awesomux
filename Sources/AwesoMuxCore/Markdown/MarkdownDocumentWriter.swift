import Foundation
import SecureFileIO

public enum MarkdownDocumentCommitFailure: Equatable, Sendable {
    case coordination(message: String)
    case write(message: String)

    public var message: String {
        switch self {
        case .coordination(let message), .write(let message): message
        }
    }
}

public enum MarkdownDocumentCommitResult: Equatable, Sendable {
    case committed(source: String)
    case observedConflict
    case unreadable
    case invalidEdit
    case outputTooLarge
    case failed(MarkdownDocumentCommitFailure)
}

public struct MarkdownDocumentSnapshot: Equatable, Sendable {
    public let resolvedURL: URL
    public let identity: SecureFileIdentity
    public let data: Data

    public init(resolvedURL: URL, identity: SecureFileIdentity, data: Data) {
        self.resolvedURL = resolvedURL
        self.identity = identity
        self.data = data
    }

    public init(contents: SecureFileContents) {
        resolvedURL = contents.resolvedURL
        identity = contents.identity
        data = contents.data
    }

    public var source: String? {
        String(data: data, encoding: .utf8)
    }
}

public enum MarkdownDocumentCommitter {
    /// Refuses any source or target change observed before the coordinated
    /// atomic replacement. `NSFileCoordinator` serializes participating
    /// writers; a process that ignores coordination can still race after the
    /// final read, so this is deliberately not presented as filesystem CAS.
    public static func commitObserved(
        at inputURL: URL,
        observed: MarkdownDocumentSnapshot,
        transform: (String) -> String?
    ) -> MarkdownDocumentCommitResult {
        commitObserved(
            at: inputURL,
            observed: observed,
            transform: transform,
            beforeRecheck: {}
        )
    }

    static func commitObserved(
        at inputURL: URL,
        renderedSource: String,
        transform: (String) -> String?,
        beforeRecheck: @escaping () throws -> Void = {},
        write: @escaping (Data, URL) throws -> Void = replacePreservingMetadata,
        coordinate: (URL, @escaping (URL) -> Void) -> NSError? = { url, accessor in
            var error: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &error,
                byAccessor: accessor
            )
            return error
        }
    ) -> MarkdownDocumentCommitResult {
        guard let contents = readBytes(at: inputURL) else { return .unreadable }
        let observed = MarkdownDocumentSnapshot(contents: contents)
        guard observed.data == Data(renderedSource.utf8) else { return .observedConflict }
        return commitObserved(
            at: inputURL,
            observed: observed,
            transform: transform,
            beforeRecheck: beforeRecheck,
            write: write,
            coordinate: coordinate
        )
    }

    static func commitObserved(
        at inputURL: URL,
        observed: MarkdownDocumentSnapshot,
        transform: (String) -> String?,
        beforeRecheck: @escaping () throws -> Void,
        write: @escaping (Data, URL) throws -> Void = replacePreservingMetadata,
        coordinate: (URL, @escaping (URL) -> Void) -> NSError? = { url, accessor in
            var error: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &error,
                byAccessor: accessor
            )
            return error
        }
    ) -> MarkdownDocumentCommitResult {
        guard let source = observed.source else { return .unreadable }
        guard let updatedSource = transform(source) else { return .invalidEdit }

        let output = Data(updatedSource.utf8)
        guard output.count <= DocumentURLValidator.maxFileSizeBytes else {
            return .outputTooLarge
        }

        var result: MarkdownDocumentCommitResult?
        let coordinationError = coordinate(observed.resolvedURL) { coordinatedURL in
            do {
                try beforeRecheck()
                guard coordinatedURL.standardizedFileURL == observed.resolvedURL.standardizedFileURL,
                    let current = readBytes(at: inputURL),
                    current.resolvedURL.standardizedFileURL
                        == observed.resolvedURL.standardizedFileURL,
                    current.identity == observed.identity,
                    current.data == observed.data
                else {
                    result = .observedConflict
                    return
                }

                try write(output, current.resolvedURL)
                result = .committed(source: updatedSource)
            } catch {
                result = .failed(.write(message: error.localizedDescription))
            }
        }

        if let result { return result }
        return .failed(
            .coordination(
                message: coordinationError?.localizedDescription ?? "File coordination did not complete."
            ))
    }

    private static func readBytes(at url: URL) -> SecureFileContents? {
        do {
            let contents = try SecureFileReader.read(
                at: url,
                maximumBytes: DocumentURLValidator.maxFileSizeBytes
            )
            guard
                DocumentURLValidator.reject(
                    contents.resolvedURL,
                    fileSize: contents.data.count
                ) == nil
            else { return nil }
            return contents
        } catch {
            return nil
        }
    }

    private static func replacePreservingMetadata(_ data: Data, at url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }
}
