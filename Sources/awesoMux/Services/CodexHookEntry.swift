import Foundation

// MARK: - HookEntry

/// One discovered hook as reported by the Codex app-server `hooks/list` RPC
/// (contract §2.4). Decodes the subset of the wire `HookMetadata` object the
/// installer needs to match awesoMux's hook by `pluginId` and read its trust
/// state. `command` is optional so older app-server output still decodes; it is
/// used only as a compatibility fallback when `pluginId` is absent. `warnings`
/// and `errors` are not hook-level at all — they live on the per-cwd wrapper.
struct HookEntry: Codable, Equatable, Sendable {
    var key: String
    var eventName: String
    var isManaged: Bool
    var pluginId: String?
    var command: String?
    var matcher: String?
    var enabled: Bool
    var currentHash: String
    var trustStatus: HookTrustStatus
    var sourcePath: String
    var source: String

    init(
        key: String,
        eventName: String,
        isManaged: Bool,
        pluginId: String?,
        command: String? = nil,
        matcher: String? = nil,
        enabled: Bool,
        currentHash: String,
        trustStatus: HookTrustStatus,
        sourcePath: String,
        source: String
    ) {
        self.key = key
        self.eventName = eventName
        self.isManaged = isManaged
        self.pluginId = pluginId
        self.command = command
        self.matcher = matcher
        self.enabled = enabled
        self.currentHash = currentHash
        self.trustStatus = trustStatus
        self.sourcePath = sourcePath
        self.source = source
    }
}

// MARK: - HookTrustStatus

/// Trust state of a Codex hook. Raw values are the exact wire strings the
/// app-server emits. A hook runs only when it is `enabled` *and* `trusted`;
/// `firstSeen`/`untrusted` mean awaiting approval (→ `Needs review`) and
/// `changed` means the computed hash diverged from the approved one.
enum HookTrustStatus: String, Codable, Equatable, Sendable {
    case firstSeen = "first-seen"
    case untrusted
    case trusted
    case changed
}
