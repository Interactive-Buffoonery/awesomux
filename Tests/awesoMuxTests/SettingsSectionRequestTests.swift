import Testing
@testable import awesoMux

@Suite("Settings section targeting")
@MainActor
struct SettingsSectionRequestTests {
    @Test("A pending section is delivered exactly once")
    func consumesOnce() {
        let request = SettingsSectionRequest()
        request.request(.agents)
        #expect(request.consume() == .agents)
        #expect(request.consume() == nil)
    }

    @Test("No request means the view keeps its own selection")
    func emptyByDefault() {
        #expect(SettingsSectionRequest().consume() == nil)
    }
}
