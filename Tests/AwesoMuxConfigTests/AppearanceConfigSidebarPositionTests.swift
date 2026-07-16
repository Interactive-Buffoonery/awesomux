import Testing
@testable import AwesoMuxConfig

@Suite("AppearanceConfig.sidebarPosition")
struct AppearanceConfigSidebarPositionTests {
    @Test func defaultsLeft() {
        #expect(AppearanceConfig.defaultValue.sidebarPosition == .left)
    }

    @Test func rightRoundTripsThroughTOML() throws {
        var config = AwesoMuxConfig.defaultValue
        config.appearance.sidebarPosition = .right
        let codec = TOMLConfigCodec()
        let encoded = try codec.encodeString(config)
        #expect(encoded.contains("sidebar_position = \"right\""))
        #expect(try codec.decode(encoded).appearance.sidebarPosition == .right)
    }
}
