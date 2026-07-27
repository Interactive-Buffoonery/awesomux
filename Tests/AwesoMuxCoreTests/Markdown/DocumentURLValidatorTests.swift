import Testing
import Foundation
@testable import AwesoMuxCore

// MARK: - DocumentURLValidator Tests

/// These tests cover every rejection path on the security boundary that guards
/// `DocumentPane.fileURL` before any I/O is attempted.
@Suite("DocumentURLValidator")
struct DocumentURLValidatorTests {

    // MARK: Helpers

    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    // MARK: - Scheme checks

    @Test("accepts a file:// URL")
    func acceptsFileURL() {
        let url = fileURL("/tmp/notes.md")
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == nil)
    }

    @Test("rejects an http:// URL")
    func rejectsHTTPURL() {
        let url = URL(string: "https://example.com/notes.md")!
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .notFileURL)
    }

    @Test("rejects a data: URL")
    func rejectsDataURL() {
        let url = URL(string: "data:text/markdown;base64,SGVsbG8=")!
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .notFileURL)
    }

    // MARK: - Extension checks

    @Test("accepts .md extension (lowercase)")
    func acceptsMdExtension() {
        let url = fileURL("/home/user/doc.md")
        #expect(DocumentURLValidator.reject(url, fileSize: 500) == nil)
    }

    @Test("accepts .markdown extension")
    func acceptsMarkdownExtension() {
        let url = fileURL("/home/user/readme.markdown")
        #expect(DocumentURLValidator.reject(url, fileSize: 500) == nil)
    }

    @Test("accepts .MD extension (case-insensitive)")
    func acceptsMDUppercase() {
        let url = fileURL("/home/user/doc.MD")
        #expect(DocumentURLValidator.reject(url, fileSize: 500) == nil)
    }

    @Test("accepts .MARKDOWN extension (case-insensitive)")
    func acceptsMarkdownUppercase() {
        let url = fileURL("/home/user/doc.MARKDOWN")
        #expect(DocumentURLValidator.reject(url, fileSize: 500) == nil)
    }

    @Test("rejects .txt extension")
    func rejectsTxtExtension() {
        let url = fileURL("/tmp/notes.txt")
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .badExtension)
    }

    @Test("rejects .png extension")
    func rejectsPNGExtension() {
        let url = fileURL("/tmp/image.png")
        #expect(DocumentURLValidator.reject(url, fileSize: 1000) == .badExtension)
    }

    @Test("rejects no extension")
    func rejectsNoExtension() {
        let url = fileURL("/tmp/README")
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .badExtension)
    }

    @Test("rejects .html extension")
    func rejectsHTMLExtension() {
        let url = fileURL("/tmp/page.html")
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .badExtension)
    }

    // MARK: - Size checks

    @Test("accepts file exactly at the size cap")
    func acceptsExactlyAtCap() {
        let url = fileURL("/tmp/big.md")
        let cap = DocumentURLValidator.maxFileSizeBytes
        #expect(DocumentURLValidator.reject(url, fileSize: cap) == nil)
    }

    @Test("rejects file one byte over the size cap")
    func rejectsOneByteOverCap() {
        let url = fileURL("/tmp/big.md")
        let cap = DocumentURLValidator.maxFileSizeBytes
        #expect(DocumentURLValidator.reject(url, fileSize: cap + 1) == .tooLarge)
    }

    @Test("rejects a very large file")
    func rejectsLargeFile() {
        let url = fileURL("/tmp/huge.md")
        #expect(DocumentURLValidator.reject(url, fileSize: 100 * 1024 * 1024) == .tooLarge)
    }

    /// Every other size test is written relative to `maxFileSizeBytes`, so the
    /// suite stays green no matter what the cap is set to. This one pins the
    /// value itself, because the value is a deliberate memory decision rather
    /// than an arbitrary limit: a rendered document costs ~138 MB of live heap
    /// per MB of source, and `NSTextLayoutManager` never releases layout
    /// fragments, so capping the input is the only thing that bounds resident
    /// memory. Raising this without a rendering strategy that avoids
    /// whole-document layout re-buys a multi-hundred-megabyte document tab.
    @Test("the size cap is pinned at 2 MB — raising it re-buys the memory problem")
    func sizeCapIsPinnedToItsMemoryBudget() {
        #expect(DocumentURLValidator.maxFileSizeBytes == 2 * 1024 * 1024)
    }

    @Test("accepts nil file size (size check skipped)")
    func acceptsNilFileSize() {
        // nil means the caller hasn't determined the size yet or the file
        // attributes couldn't be read; the validator skips the size gate.
        // DocumentLoader maps a nil-attributes result to .unreadable separately.
        let url = fileURL("/tmp/notes.md")
        #expect(DocumentURLValidator.reject(url, fileSize: nil) == nil)
    }

    // MARK: - Priority ordering

    @Test("scheme check fires before extension check")
    func schemePrecedesExtension() {
        // https URL with a .md path — scheme should be caught first
        let url = URL(string: "https://example.com/notes.md")!
        #expect(DocumentURLValidator.reject(url, fileSize: 100) == .notFileURL)
    }

    @Test("extension check fires before size check")
    func extensionPrecedesSize() {
        let url = fileURL("/tmp/secret.txt")
        // Even if the file is tiny, the extension is wrong — extension fires first
        #expect(DocumentURLValidator.reject(url, fileSize: 10) == .badExtension)
    }
}
