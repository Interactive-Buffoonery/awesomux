import Foundation

// MARK: - DocumentURLValidator

/// Guards the `DocumentPane.fileURL` path before reading it.
///
/// The `fileURL` is persisted in the session snapshot, which is user-writable from any
/// terminal pane. This validator is the security boundary: reject anything that doesn't
/// look like a local markdown file of acceptable size *before* attempting an I/O read.
///
/// The validator is pure — `fileSize` is passed from the loader's validated descriptor,
/// keeping this type testable without filesystem side-effects.
public enum DocumentURLValidator {

    /// Maximum file size the viewer will read (2 MiB).
    ///
    /// This is a **memory** ceiling, not a parsing or security one. A rendered
    /// markdown document costs roughly **138 MB of live heap per MiB of source**
    /// (measured 2026-07-27: 1 MB source → 204 MB live / 1,004,352 allocations;
    /// 9.5 MB source → 1.4 GB live / 7,391,024 allocations), because sizing the
    /// text view forces TextKit 2 to lay out the whole document and CoreText
    /// materializes `CTLine`/`CTRun`/glyph storage for every line.
    ///
    /// That cost is **not** recoverable by laying out lazily:
    /// `NSTextLayoutManager` never evicts layout fragments, so a viewport-scoped
    /// document reaches the same resident memory as soon as the user scrolls
    /// through it (verified — post-traversal fragment count is identical to
    /// eager). Capping the input is therefore the only lever that bounds the
    /// ceiling.
    ///
    /// 2 MiB puts the worst case near 275 MB while staying far above real
    /// workloads — the largest plan or spec document in this repository's own
    /// history is well under 100 KB.
    ///
    /// ponytail: raise this only alongside a rendering strategy that does not
    /// hold whole-document layout — tearing down and rebuilding the layout
    /// manager on scroll, or a separate large-document mode that does not use
    /// TextKit 2. Raising it alone re-buys the memory problem at 138 MB per MiB.
    public static let maxFileSizeBytes = 2 * 1024 * 1024

    /// File extensions accepted by the viewer.
    public static let allowedExtensions: Set<String> = ["md", "markdown"]

    /// Reasons a URL is rejected.
    public enum Rejection: Equatable, Sendable {
        /// The URL does not use the `file://` scheme.
        case notFileURL
        /// The file extension is not in `allowedExtensions`.
        case badExtension
        /// The file is larger than `maxFileSizeBytes`.
        case tooLarge
        /// The file was not accessible / readable (e.g. permission error, does not exist).
        case unreadable
    }

    /// Returns `nil` if `url` is safe to read, or the rejection reason otherwise.
    ///
    /// - Parameters:
    ///   - url: The URL to validate.
    ///   - fileSize: The size of the file in bytes, as reported by `FileManager`.
    ///     Pass `nil` when the file was unreadable and let the caller map that to
    ///     `.unreadable` separately — OR pass `nil` here to skip the size check
    ///     (e.g. when size is unknown and the caller will handle it). In practice,
    ///     the loader always opens and validates the descriptor first and either
    ///     passes its size or returns `.unreadable` when opening fails.
    public static func reject(_ url: URL, fileSize: Int?) -> Rejection? {
        guard url.isFileURL else { return .notFileURL }

        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return .badExtension }

        if let size = fileSize, size > maxFileSizeBytes { return .tooLarge }

        return nil
    }
}
