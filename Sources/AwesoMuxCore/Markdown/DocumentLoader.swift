import Darwin
import Foundation
import SecureFileIO

// MARK: - DocumentLoader

/// Opens and validates a file URL, reads its contents, and builds the render model.
///
/// This is the testable seam between URL validation + I/O and the SwiftUI view.
/// Keeping the logic here (not in the view) allows unit tests to exercise every
/// rejection and read-error path without a SwiftUI harness.
public enum DocumentLoader {

    private enum SourceResult {
        case snapshot(MarkdownDocumentSnapshot)
        case failure(LoadResult)
    }

    // MARK: - Result type

    /// The outcome of a load attempt.
    public enum LoadResult: Equatable, Sendable {
        /// The document was successfully read and parsed.
        case loaded([MarkdownBlock], source: String, snapshot: MarkdownDocumentSnapshot?)
        /// The URL was rejected before any I/O was attempted.
        case rejected(DocumentURLValidator.Rejection)
        /// The URL was valid but the file could not be read (e.g. permissions, deleted).
        case readError(String)
    }

    // MARK: - Load

    /// Opens `url` once, validates that descriptor, reads its UTF-8 content,
    /// and builds `[MarkdownBlock]`.
    ///
    /// - Parameters:
    ///   - url: The file URL to load.
    /// - Returns: A `LoadResult` indicating success or the failure reason.
    public static func load(
        _ url: URL
    ) -> LoadResult {
        load(url, effectiveUID: geteuid())
    }

    package static func load(source: String) -> LoadResult {
        .loaded(MarkdownRenderModelBuilder.build(source), source: source, snapshot: nil)
    }

    package static func loadAndRender(
        load: @Sendable () async -> LoadResult,
        priorDocument: RenderedDocument?,
        render: @Sendable (String) async -> RenderedDocument
    ) async -> (LoadResult, RenderedDocument?)? {
        guard !Task.isCancelled else { return nil }
        let result = await load()
        guard !Task.isCancelled else { return nil }
        guard case let .loaded(_, source, _) = result else {
            return (result, nil)
        }
        if let priorDocument, priorDocument.source.utf8.elementsEqual(source.utf8) {
            return (result, priorDocument)
        }
        guard !Task.isCancelled else { return nil }
        let document = await render(source)
        guard !Task.isCancelled else { return nil }
        return (result, document)
    }

    /// Reads a document source through the same validation and byte cap as `load(_:)`.
    package static func readSource(
        _ url: URL
    ) -> String? {
        readSnapshot(url)?.source
    }

    package static func readSnapshot(_ url: URL) -> MarkdownDocumentSnapshot? {
        guard case let .snapshot(snapshot) = readSource(url, effectiveUID: geteuid()) else { return nil }
        return snapshot
    }

    static func load(
        _ url: URL,
        effectiveUID: uid_t
    ) -> LoadResult {
        switch readSource(url, effectiveUID: effectiveUID) {
        case let .snapshot(snapshot):
            guard let source = snapshot.source else {
                return .readError("The file couldn’t be opened because it isn’t in the correct format.")
            }
            return .loaded(
                MarkdownRenderModelBuilder.build(source),
                source: source,
                snapshot: snapshot
            )
        case let .failure(result):
            return result
        }
    }

    private static func readSource(
        _ url: URL,
        effectiveUID: uid_t
    ) -> SourceResult {
        guard url.isFileURL else {
            return .failure(.rejected(.notFileURL))
        }

        let handle: SecureFileReadHandle
        do {
            handle = try SecureFileReader.open(at: url, effectiveUID: effectiveUID)
        } catch {
            return .failure(.rejected(.unreadable))
        }

        guard let fileSize = Int(exactly: handle.size) else {
            return .failure(.rejected(.unreadable))
        }
        if let rejection = DocumentURLValidator.reject(
            handle.resolvedURL,
            fileSize: fileSize
        ) {
            return .failure(.rejected(rejection))
        }

        do {
            let data = try handle.read(maximumBytes: DocumentURLValidator.maxFileSizeBytes)
            guard String(data: data, encoding: .utf8) != nil else {
                return .failure(.readError("The file couldn’t be opened because it isn’t in the correct format."))
            }
            return .snapshot(
                MarkdownDocumentSnapshot(
                    resolvedURL: handle.resolvedURL,
                    identity: handle.identity,
                    data: data
                )
            )
        } catch SecureFileReadError.tooLarge {
            return .failure(.rejected(.tooLarge))
        } catch {
            return .failure(.readError("The file couldn’t be read."))
        }
    }
}
