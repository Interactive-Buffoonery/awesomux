import AwesoMuxConfig
import SwiftUI

/// Back-compat whole-tree binding. New code should prefer per-section
/// bindings (`appSettingsStore.appearance.binding(\.theme)` etc.) to get
/// finer-grained @Observable invalidation — the whole-tree binding read
/// depends on every section.
@MainActor
extension AppSettingsStore {
    func binding<Value>(
        _ keyPath: WritableKeyPath<AwesoMuxConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in
                self.update { config in
                    config[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

@MainActor
extension SectionSlice {
    /// Per-section binding helper. Reads depend only on this section's
    /// store, so SwiftUI invalidates only the views that touch this
    /// slice. On the concrete slice, not the SectionStore protocol — the
    /// protocol has exactly one conformer; move this back up only if a
    /// second store or a polymorphic call site ever appears.
    func binding<T>(_ keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { newValue in
                self.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}
