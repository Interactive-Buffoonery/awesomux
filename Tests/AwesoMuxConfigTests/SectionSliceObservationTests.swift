import Observation
import Testing

@testable import AwesoMuxConfig

/// `@Observable` on a generic class is less common than on concrete ones;
/// this pins down that `SectionSlice<Value>.value` still participates in
/// observation tracking after the INT-658 collapse.
@MainActor
@Suite("SectionSlice observation")
struct SectionSliceObservationTests {
    @Test("value mutation fires observation tracking")
    func valueMutationFiresObservation() async {
        let slice = SectionSlice(GeneralConfig.defaultValue, keyPath: \.general)

        await confirmation { changed in
            withObservationTracking {
                _ = slice.value
            } onChange: {
                changed()
            }

            slice.update { $0 = GeneralConfig.defaultValue }  // no-op: must not fire
            var mutated = GeneralConfig.defaultValue
            slice.update { $0 = mutated }  // still equal: must not fire
            mutated.sidebarCompactMode.toggle()
            slice.update { $0 = mutated }
        }
    }
}
