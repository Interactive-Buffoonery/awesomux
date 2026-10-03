import AwesoMuxConfig
import SwiftUI

@MainActor
extension SectionSlice {
    /// Per-section binding helper. Reads depend only on this section's
    /// store, so SwiftUI invalidates only the views that touch this
    /// slice.
    func binding<T>(_ keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { newValue in
                self.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}
