import Testing
@testable import DesignSystem

@Suite("CollapsedStatusBadge")
struct CollapsedStatusBadgeTests {
    @Test("needs and error keep a glyph")
    func loudStatesKeepGlyph() {
        #expect(CollapsedStatusBadge.resolve(for: .needs) == .glyph(.exclamation))
        #expect(CollapsedStatusBadge.resolve(for: .error) == .glyph(.cross))
    }
    @Test("idle renders no badge")
    func idleHasNoBadge() {
        #expect(CollapsedStatusBadge.resolve(for: .idle) == nil)
    }
    @Test("every other state is a plain dot")
    func otherStatesAreDots() {
        // Drive from CaseIterable so any future AwState addition is automatically covered.
        let dotStates = AwState.allCases.filter { $0 != .needs && $0 != .error && $0 != .idle }
        for state in dotStates {
            #expect(CollapsedStatusBadge.resolve(for: state) == .dot)
        }
    }
}
