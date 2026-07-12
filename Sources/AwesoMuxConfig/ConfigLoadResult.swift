import Foundation

public enum ConfigLoadSource: Equatable, Sendable {
    case existingFile
    case createdDefault
    case migratedLegacy
    case invalidExistingFile
    case unreadableExistingFile
}

public struct ConfigLoadResult: Equatable, Sendable {
    public var config: AwesoMuxConfig?
    public var source: ConfigLoadSource
    public var error: ConfigLoadError?
    public var configURL: URL

    public init(
        config: AwesoMuxConfig?,
        source: ConfigLoadSource,
        error: ConfigLoadError? = nil,
        configURL: URL
    ) {
        self.config = config
        self.source = source
        self.error = error
        self.configURL = configURL
    }
}
