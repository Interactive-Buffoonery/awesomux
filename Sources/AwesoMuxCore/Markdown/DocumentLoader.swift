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

    // MARK: - Result type

    /// The outcome of a load attempt.
    public enum LoadResult: Equatable, Sendable {
        /// The document was successfully read and parsed.
        case loaded([MarkdownBlock], source: String)
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

    static func load(
        _ url: URL,
        effectiveUID: uid_t
    ) -> LoadResult {
        guard url.isFileURL else {
            return .rejected(.notFileURL)
        }

        let handle: SecureFileReadHandle
        do {
            handle = try SecureFileReader.open(at: url, effectiveUID: effectiveUID)
        } catch {
            return .rejected(.unreadable)
        }

        guard let fileSize = Int(exactly: handle.size) else {
            return .rejected(.unreadable)
        }
        if let rejection = DocumentURLValidator.reject(
            handle.resolvedURL,
            fileSize: fileSize
        ) {
            return .rejected(rejection)
        }

        do {
            let data = try handle.read(maximumBytes: DocumentURLValidator.maxFileSizeBytes)
            guard let content = String(data: data, encoding: .utf8) else {
                return .readError("The file couldn’t be opened because it isn’t in the correct format.")
            }
            return .loaded(MarkdownRenderModelBuilder.build(content), source: content)
        } catch SecureFileReadError.tooLarge {
            return .rejected(.tooLarge)
        } catch {
            return .readError("The file couldn’t be read.")
        }
    }
}
