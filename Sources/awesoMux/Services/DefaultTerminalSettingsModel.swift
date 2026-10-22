import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DefaultTerminalSettingsModel {
    static let contentTypes: [UTType] = [.unixExecutable, UTType(importedAs: "com.apple.terminal.shell-script")]

    private(set) var isDefault = false
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    let applicationURL: URL
    @ObservationIgnored private let defaultApplication: (UTType) -> URL?
    @ObservationIgnored private let setDefaultApplication: (UTType) async throws -> Void

    init(
        applicationURL: URL = Bundle.main.bundleURL,
        defaultApplication: @escaping (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        setDefaultApplication: ((UTType) async throws -> Void)? = nil
    ) {
        self.applicationURL = applicationURL
        self.defaultApplication = defaultApplication
        self.setDefaultApplication =
            setDefaultApplication ?? { type in
                try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type)
            }
    }

    func refresh() {
        isDefault = Self.contentTypes.allSatisfy {
            defaultApplication($0)?.resolvingSymlinksInPath() == applicationURL.resolvingSymlinksInPath()
        }
    }

    func makeDefault() async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer {
            refresh()
            isUpdating = false
        }
        do {
            for type in Self.contentTypes {
                try await setDefaultApplication(type)
            }
        } catch {
            errorMessage = String(localized: "Could not update all terminal file associations. Check the macOS confirmation and try again.")
        }
    }
}
