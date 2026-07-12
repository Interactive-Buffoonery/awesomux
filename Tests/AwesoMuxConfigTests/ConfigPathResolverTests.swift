import AwesoMuxConfig
import Foundation
import Testing

@Suite("ConfigPathResolver")
struct ConfigPathResolverTests {
    private let homeURL = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    @Test("default resolver uses production config directory")
    func defaultConfigDirectory() {
        let resolver = ConfigPathResolver(homeDirectory: homeURL)

        #expect(resolver.configFileURL.path == "/Users/example/.config/awesomux/config.toml")
    }

    @Test("custom resolver can target the development config directory")
    func customConfigDirectory() {
        let resolver = ConfigPathResolver(
            homeDirectory: homeURL,
            configDirectoryName: "awesomux-dev"
        )

        #expect(resolver.configFileURL.path == "/Users/example/.config/awesomux-dev/config.toml")
    }
}
