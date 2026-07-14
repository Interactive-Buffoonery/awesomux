import Foundation
import SecureFileIO

public enum MarkdownDocumentWriteResult: Equatable, Sendable {
    case written(source: String)
    case conflict
    case unreadable
    case invalidEdit
    case writeFailed
}

public enum MarkdownDocumentWriter {
    public static func applyIfCurrent(
        at url: URL,
        expectedSource: String,
        transform: (String) -> String?
    ) -> MarkdownDocumentWriteResult {
        applyIfCurrent(
            at: url,
            expectedSource: expectedSource,
            transform: transform,
            beforeReplacement: {}
        )
    }

    static func applyIfCurrent(
        at url: URL,
        expectedSource: String,
        transform: (String) -> String?,
        beforeReplacement: () throws -> Void
    ) -> MarkdownDocumentWriteResult {
        guard let original = read(at: url) else { return .unreadable }
        guard original.source == expectedSource else { return .conflict }
        guard let updatedSource = transform(original.source) else { return .invalidEdit }

        var result = MarkdownDocumentWriteResult.writeFailed
        NSFileCoordinator().coordinate(
            writingItemAt: original.resolvedURL,
            options: .forReplacing,
            error: nil
        ) { coordinatedURL in
            do {
                try beforeReplacement()
                guard let current = read(at: coordinatedURL) else {
                    result = .unreadable
                    return
                }
                guard current.data == original.data else {
                    result = .conflict
                    return
                }

                try Data(updatedSource.utf8).write(to: current.resolvedURL, options: .atomic)
                result = .written(source: updatedSource)
            } catch {
                result = .writeFailed
            }
        }
        return result
    }

    private struct Contents {
        let resolvedURL: URL
        let data: Data
        let source: String
    }

    private static func read(at url: URL) -> Contents? {
        do {
            let contents = try SecureFileReader.read(
                at: url,
                maximumBytes: DocumentURLValidator.maxFileSizeBytes
            )
            guard
                DocumentURLValidator.reject(
                    contents.resolvedURL,
                    fileSize: contents.data.count
                ) == nil,
                let source = String(data: contents.data, encoding: .utf8)
            else { return nil }
            return Contents(
                resolvedURL: contents.resolvedURL,
                data: contents.data,
                source: source
            )
        } catch {
            return nil
        }
    }
}
