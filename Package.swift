// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "awesoMux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "awesoMux", targets: ["awesoMux"]),
        .executable(name: "awesoMuxAgentHook", targets: ["awesoMuxAgentHook"]),
        .executable(name: "awesoMuxBridgeHelper", targets: ["awesoMuxBridgeHelper"]),
        .library(name: "AwesoMuxCore", targets: ["AwesoMuxCore"]),
        .library(name: "AwesoMuxConfig", targets: ["AwesoMuxConfig"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "awesoMux",
            dependencies: [
                "AwesoMuxCore",
                "AwesoMuxConfig",
                "DesignSystem",
                "UnicodeHygiene",
                "GhosttyKit",
                "GhosttyKitLinker",
            ]
        ),
        .target(
            name: "AwesoMuxConfig",
            dependencies: [
                "SecureFileIO",
                "UnicodeHygiene",
                .product(name: "TOML", package: "swift-toml"),
            ]
        ),
        .target(
            name: "AwesoMuxCore",
            dependencies: [
                "SecureFileIO",
                "UnicodeHygiene",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "AwesoMuxAgentHookSupport",
            dependencies: ["AwesoMuxCore"]
        ),
        .target(
            name: "AwesoMuxBridgeHelperSupport",
            dependencies: ["AwesoMuxCore"]
        ),
        .executableTarget(
            name: "awesoMuxAgentHook",
            dependencies: ["AwesoMuxCore", "AwesoMuxAgentHookSupport"],
            path: "Sources/AwesoMuxAgentHook"
        ),
        .executableTarget(
            name: "awesoMuxBridgeHelper",
            dependencies: ["AwesoMuxCore", "AwesoMuxBridgeHelperSupport"],
            path: "Sources/awesoMuxBridgeHelper"
        ),
        .target(name: "UnicodeHygiene"),
        .target(
            name: "DesignSystem",
            resources: [.copy("Resources/Fonts")]
        ),
        .target(name: "SecureFileIO"),
        .target(
            name: "AwesoMuxTestSupport",
            dependencies: ["AwesoMuxCore"],
            path: "Tests/AwesoMuxTestSupport"
        ),
        .systemLibrary(
            name: "GhosttyKit",
            path: "Sources/GhosttyKit"
        ),
        .target(
            name: "GhosttyKitLinker",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                // Transitive: libghostty's imgui_impl_osx.o references GCController.
                // ReleaseFast surfaced the unresolved symbol that Debug let pass.
                .linkedFramework("GameController"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
                .linkedLibrary("stdc++"),
                // SwiftPM evaluates unsafeFlags paths as package-root-relative. These
                // intentionally point into .build/ghostty, which
                // script/build_ghostty_xcframework.sh produces for local builds.
                // Because .build/ is user-writable, this linker setup is appropriate
                // only for trusted local/dev/CI checkouts. The macos-arm64 artifact
                // path is intentional: awesoMux is Apple Silicon-only for now.
                .unsafeFlags([
                    "-Xlinker",
                    "-force_load",
                    "-Xlinker",
                    // ghostty >= #12653 combines libghostty + all C/C++ deps
                    // (imgui, freetype, glslang, sentry, …) into one archive
                    // (`ghostty-internal` → libghostty-internal-fat.a, copied
                    // here as libghostty-fat.a). Force-loading it alone replaces
                    // the old fat-plus-15-individual-archives list; the split
                    // also dropped libutfcpp.a entirely.
                    ".build/ghostty/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a",
                ]),
            ]
        ),
        .testTarget(
            name: "AwesoMuxCoreTests",
            dependencies: ["AwesoMuxCore", "AwesoMuxTestSupport"]
        ),
        .testTarget(
            name: "AwesoMuxConfigTests",
            dependencies: ["AwesoMuxConfig", "AwesoMuxTestSupport"]
        ),
        .testTarget(
            name: "AwesoMuxAgentHookSupportTests",
            dependencies: ["AwesoMuxAgentHookSupport", "AwesoMuxCore"]
        ),
        .testTarget(
            name: "AwesoMuxBridgeHelperSupportTests",
            dependencies: ["AwesoMuxBridgeHelperSupport", "AwesoMuxCore", "AwesoMuxTestSupport"]
        ),
        .testTarget(
            name: "UnicodeHygieneTests",
            dependencies: ["UnicodeHygiene"]
        ),
        .testTarget(
            name: "SecureFileIOTests",
            dependencies: ["SecureFileIO", "AwesoMuxTestSupport"]
        ),
        .testTarget(
            name: "awesoMuxTests",
            dependencies: ["awesoMux", "AwesoMuxCore", "AwesoMuxTestSupport", "DesignSystem"]
        ),
        .testTarget(
            name: "AwesoMuxTestSupportTests",
            dependencies: ["AwesoMuxTestSupport"]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"]
        ),
    ]
)
