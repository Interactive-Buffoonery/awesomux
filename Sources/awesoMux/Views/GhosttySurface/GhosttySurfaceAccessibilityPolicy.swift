import Foundation

/// Pure range/line arithmetic backing `GhosttySurfaceNSView`'s NSAccessibility
/// content accessors, split out because `String`/`NSRange` math is testable
/// without a live surface or AX runtime. Mirrors Ghostty's
/// `accessibilityLine(for:)` / `accessibilityString(for:)`
/// (`SurfaceView_AppKit.swift:2333-2345`).
enum GhosttySurfaceAccessibilityPolicy {
    /// Line number (0-indexed) containing `index` within `content`, counted
    /// by newlines in the prefix up to `index`. Ported from Ghostty's
    /// `accessibilityLine(for:)` (`SurfaceView_AppKit.swift:2333-2337`,
    /// including its `.newlines`-CharacterSet split, which counts a `\r\n`
    /// pair as two line breaks rather than one grapheme cluster); `index` is
    /// clamped to `>= 0` before slicing because a negative length isn't a
    /// valid offset and NSAccessibility's documented index contract doesn't
    /// rule one out.
    ///
    /// `index` is a UTF-16 code-unit offset, not a grapheme-cluster count —
    /// NSAccessibility hands in and expects UTF-16 offsets (see
    /// `accessibilityString(for:)`, which already relies on this via
    /// `Range(_:in:)`). Slicing with `String.prefix(_:)` on a raw `Int` would
    /// be grapheme-based instead and desync from VoiceOver's own offsets the
    /// moment `content` contains a multi-UTF-16-unit character (emoji,
    /// combining marks, etc.), so this goes through `Range(NSRange, in:)` —
    /// the same UTF-16-aware conversion — instead.
    static func lineIndex(forCharacterIndex index: Int, in content: String) -> Int {
        let clamped = max(0, index)
        let utf16Length = (content as NSString).length
        let boundedLength = min(clamped, utf16Length)
        guard let prefixRange = Range(NSRange(location: 0, length: boundedLength), in: content) else {
            // `boundedLength` split a UTF-16 surrogate pair (or otherwise
            // doesn't land on a valid boundary) — this shouldn't happen for
            // offsets VoiceOver itself hands back, but fail safe rather than
            // trap.
            return 0
        }
        let substring = String(content[prefixRange])
        return substring.components(separatedBy: .newlines).count - 1
    }

    /// Substring of `content` at `range`, or `nil` if `range` doesn't map
    /// onto `content` (mirrors `Range(_:in:)` returning `nil` for an
    /// out-of-bounds `NSRange`, exactly as Ghostty's
    /// `accessibilityString(for:)` relies on).
    static func substring(for range: NSRange, in content: String) -> String? {
        guard let swiftRange = Range(range, in: content) else {
            return nil
        }
        return String(content[swiftRange])
    }
}
