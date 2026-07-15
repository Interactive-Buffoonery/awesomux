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

public enum MarkdownDocumentCommitter {
    /// Refuses any source or target change observed before the coordinated
    /// atomic replacement. `NSFileCoordinator` serializes participating
    /// writers; a process that ignores coordination can still race after the
    /// final read, so this is deliberately not presented as filesystem CAS.
    public static func commitObserved(
        at inputURL: URL,
        renderedSource: String,
        transform: (String) -> String?
    ) -> MarkdownDocumentCommitResult {
        commitObserved(
            at: inputURL,
            renderedSource: renderedSource,
            transform: transform,
            beforeRecheck: {}
        )
    }

    static func commitObserved(
        at inputURL: URL,
        renderedSource: String,
        transform: (String) -> String?,
        beforeRecheck: @escaping () throws -> Void,
        write: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
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
        guard let original = readSource(at: inputURL) else { return .unreadable }
        guard original.source == renderedSource else { return .observedConflict }
        guard let updatedSource = transform(original.source) else { return .invalidEdit }

        let output = Data(updatedSource.utf8)
        guard output.count <= DocumentURLValidator.maxFileSizeBytes else {
            return .outputTooLarge
        }

        var result: MarkdownDocumentCommitResult?
        let coordinationError = coordinate(original.contents.resolvedURL) { coordinatedURL in
            do {
                try beforeRecheck()
                guard coordinatedURL.standardizedFileURL == original.contents.resolvedURL.standardizedFileURL,
                    let current = readBytes(at: inputURL),
                    current.resolvedURL.standardizedFileURL
                        == original.contents.resolvedURL.standardizedFileURL,
                    current.identity == original.contents.identity,
                    current.data == original.contents.data
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

    private struct SourceContents {
        let contents: SecureFileContents
        let source: String
    }

    private static func readSource(at url: URL) -> SourceContents? {
        guard let contents = readBytes(at: url),
            let source = String(data: contents.data, encoding: .utf8)
        else { return nil }
        return SourceContents(contents: contents, source: source)
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
}
