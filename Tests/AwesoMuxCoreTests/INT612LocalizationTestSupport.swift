import Foundation

enum INT612LocalizationTestSupport {
    static var bundle: Bundle? {
        Bundle(url: fixtureURL.appending(path: "fr.lproj", directoryHint: .isDirectory))
    }

    static let french = Locale(identifier: "fr")

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/INT612Localization.bundle", directoryHint: .isDirectory)
    }
}
