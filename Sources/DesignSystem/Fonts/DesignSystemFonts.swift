import CoreText
import Foundation
import os

public enum DesignSystemFonts {
    public struct RegistrationResult: Equatable, Sendable {
        public let registeredPostScriptNames: [String]
        public let failures: [String]
    }

    public static let geistFamilyName = "Geist"

    private static let fontNames = [
        "Geist-Regular",
        "Geist-Medium",
        "Geist-SemiBold",
        "Geist-Bold"
    ]
    private static let registration = OSAllocatedUnfairLock<RegistrationResult?>(initialState: nil)
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "fonts"
    )

    /// Registers the bundled UI faces for this process. Repeated calls return
    /// the first result without asking Core Text to register the same files.
    @discardableResult
    public static func registerBundledFonts() -> RegistrationResult {
        registration.withLock { result in
            if let result {
                return result
            }

            let registrationResult = registerGeistFonts()
            for failure in registrationResult.failures {
                logger.error("Bundled font registration failed: \(failure, privacy: .public)")
            }
            result = registrationResult
            return registrationResult
        }
    }

    private static func registerGeistFonts() -> RegistrationResult {
        var registeredPostScriptNames: [String] = []
        var failures: [String] = []

        for fontName in fontNames {
            guard let url = bundledFontURL(named: fontName) else {
                failures.append("missing resource \(fontName).ttf")
                continue
            }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registeredPostScriptNames.append(fontName)
            } else if fontIsAvailable(postScriptName: fontName) {
                registeredPostScriptNames.append(fontName)
            } else {
                let message = error?.takeRetainedValue().localizedDescription
                    ?? "Core Text returned no error"
                failures.append("\(fontName).ttf: \(message)")
            }
        }

        return RegistrationResult(
            registeredPostScriptNames: registeredPostScriptNames,
            failures: failures
        )
    }

    private static func fontIsAvailable(postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 13, nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName
    }

    private static func bundledFontURL(named name: String) -> URL? {
        // SwiftPM's generated accessor checks the app root, but signed macOS
        // bundles must keep this nested bundle under Contents/Resources.
        let stagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("awesoMux_DesignSystem.bundle") }
            .flatMap(Bundle.init(url:))
        let bundle = stagedBundle ?? Bundle.module

        return bundle.url(
            forResource: name,
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) ?? bundle.url(forResource: name, withExtension: "ttf")
    }
}
