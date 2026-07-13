import Foundation

public struct ResourcePath: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct ResourceIdentity: Codable, Hashable, Sendable {
  public let location: ExecutionLocation
  public let path: ResourcePath

  public init(location: ExecutionLocation, path: ResourcePath) {
    self.location = location
    self.path = path
  }
}
