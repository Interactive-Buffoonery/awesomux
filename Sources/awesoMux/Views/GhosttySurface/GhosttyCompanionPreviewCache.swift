import AwesoMuxCore
import Foundation

/// Per-view, per-native-surface cache. Retains only a sanitized bounded line,
/// including nil reads, so bursts cannot repeatedly extract native screen text.
@MainActor
struct GhosttyCompanionPreviewCache {
    private var source: UInt64?
    private var value: String?
    private var expiresAt: ContinuousClock.Instant?

    static let duration: Duration = .milliseconds(500)

    mutating func get(
        source: UInt64?, now: ContinuousClock.Instant = .now,
        readScreen: () -> String?
    ) -> String? {
        guard let source else {
            invalidate()
            return nil
        }
        if self.source == source, let expiresAt, now < expiresAt {
            return value
        }
        let preview = CompanionPanePreview.lastLine(in: readScreen())
        self.source = source
        value = preview
        expiresAt = now + Self.duration
        return preview
    }

    mutating func invalidate() {
        source = nil
        value = nil
        expiresAt = nil
    }
}
