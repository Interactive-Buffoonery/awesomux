import Testing

@Suite("Settings copy catalog")
struct SettingsCopyCatalogTests {
    // These exercise custom component copy, shared hints and interpolation:
    // SwiftUI's automatic extraction does not see the component arguments.
    @Test func settingsCopyReachesTheShippedCatalog() throws {
        let keys = try AwesoMuxStringCatalog.keys()
        for key in [
            "Style picker lands once the runtime exposes a setter.",
            "Provider-owned files that report identity and coarse runtime state.",
            "TOML at %@.",
            "Play the default notification sound.",
            "Stops awesoMux offering to convert SSH connections. Destinations on the always-manage list above keep converting — remove them there to stop that too.",
        ] {
            #expect(keys.contains(key), "Settings copy is missing from the shipped catalog: \(key)")
        }
    }
}
