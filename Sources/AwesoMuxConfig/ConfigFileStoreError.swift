import Foundation

public enum ConfigFileStoreError: Error, Equatable, Sendable {
    case cannotCreateDirectory(URL, message: String)
    case cannotWrite(URL, message: String)
    case invalidConfig(ConfigLoadError)

    public var displayText: String {
        switch self {
        case .cannotCreateDirectory(let url, let message):
            return "Unable to create \(abbreviateHome(url.path)): \(message)"
        case .cannotWrite(let url, let message):
            return "Unable to write \(abbreviateHome(url.path)): \(message)"
        case .invalidConfig(let error):
            return error.displayText
        }
    }
}
