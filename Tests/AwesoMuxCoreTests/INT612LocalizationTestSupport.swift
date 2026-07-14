import Foundation

enum INT612LocalizationTestSupport {
    static var bundle: Bundle? {
        Bundle(url: fixtureURL.appending(path: "zz.lproj", directoryHint: .isDirectory))
    }

    static let pseudoLocale = Locale(identifier: "zz")

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/INT612Localization.bundle", directoryHint: .isDirectory)
    }
}
