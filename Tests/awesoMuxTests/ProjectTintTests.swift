import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("ProjectTint")
struct ProjectTintTests {
    @Test("default group tint cycle uses visible picker accents")
    func defaultGroupTintCycleUsesVisiblePickerAccents() {
        let expected: [AwTintAccent] = [.teal, .green, .blue, .pink, .yellow, .red, .gray]
        let actual = expected.indices.map { index in
            ProjectTint(groupName: "Group \(index)", color: nil, index: index).accent
        }

        #expect(actual == expected)
    }

    @Test("explicit legacy group tints still render")
    func explicitLegacyGroupTintsStillRender() {
        #expect(ProjectTint(groupName: "legacy", color: .sky, index: 0).accent == .sky)
        #expect(ProjectTint(groupName: "legacy", color: .lavender, index: 0).accent == .lavender)
    }
}
