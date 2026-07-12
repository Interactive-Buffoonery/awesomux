import Foundation
import Observation

/// Per-section `@Observable` slices of `AwesoMuxConfig`. SwiftUI's
/// `@Observable` tracks reads at the class-property granularity, so a
/// single store with a struct `config` property invalidates every view
/// on any setting change. Splitting the slices into individual stores
/// lets each pane / terminal-pane / sidebar item depend only on the
/// section it actually reads — toggling cursor glow no longer
/// re-renders every visible body.
///
/// Section stores are owned by `AppSettingsStore` (the persistence
/// coordinator). Writes go through `update(_:)` on each store, which
/// composes a candidate `AwesoMuxConfig`, asks the coordinator to save
/// it, and only commits the new value when the save succeeds. A failed
/// save leaves the in-memory section value unchanged so memory and
/// disk stay consistent.
@MainActor
public protocol SectionStore: AnyObject {
    associatedtype Value: Equatable
    var value: Value { get }
    func update(_ transform: (inout Value) -> Void)
}

/// The one concrete section store: a generic `@Observable` slice spliced
/// into `AwesoMuxConfig` via a writable key path.
@MainActor
@Observable
public final class SectionSlice<Value: Equatable>: SectionStore {
    public internal(set) var value: Value
    @ObservationIgnored weak var coordinator: AppSettingsStore?
    @ObservationIgnored private let keyPath: WritableKeyPath<AwesoMuxConfig, Value>

    init(
        _ value: Value,
        keyPath: WritableKeyPath<AwesoMuxConfig, Value>,
        coordinator: AppSettingsStore? = nil
    ) {
        self.value = value
        self.keyPath = keyPath
        self.coordinator = coordinator
    }

    public func update(_ transform: (inout Value) -> Void) {
        var next = value
        transform(&next)
        guard next != value else { return }
        if let coordinator {
            var candidate = coordinator.config
            candidate[keyPath: keyPath] = next
            guard coordinator.attemptPersist(candidate) else { return }
        }
        value = next
    }
}

// MARK: - Named section aliases

public typealias GeneralStore = SectionSlice<GeneralConfig>
public typealias AppearanceStore = SectionSlice<AppearanceConfig>
public typealias NotificationStore = SectionSlice<NotificationConfig>
public typealias AgentStore = SectionSlice<AgentConfig>
public typealias AgentIntegrationsStore = SectionSlice<AgentIntegrationsConfig>
public typealias KeyboardStore = SectionSlice<KeyboardConfig>
public typealias TerminalStore = SectionSlice<TerminalConfig>
public typealias WorkspaceStore = SectionSlice<WorkspaceConfig>
public typealias AdvancedStore = SectionSlice<AdvancedConfig>
