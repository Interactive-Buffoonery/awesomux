import Foundation

public enum LocalAPIContextSource: String, Codable, Sendable {
    case transcript
    case terminalHistory = "terminal_history"
}

public struct LocalAPIContextGrant: Codable, Equatable, Sendable {
    public let paneID: UUID
    public let targetVersion: UUID
    public let allowTerminalHistory: Bool

    public init(paneID: UUID, targetVersion: UUID, allowTerminalHistory: Bool = false) {
        self.paneID = paneID
        self.targetVersion = targetVersion
        self.allowTerminalHistory = allowTerminalHistory
    }
}

public struct LocalAPIAgentContext: Codable, Sendable {
    public let paneID: UUID
    public let workspaceID: UUID
    public let targetVersion: UUID
    public let provider: String
    public let providerSessionID: String?
    public let source: LocalAPIContextSource
    public let capturedAt: Date
    public let content: String
    public let byteCount: Int
    public let truncated: Bool
    public let untrusted: Bool

    public init(agent: LocalAPIAgent, source: LocalAPIContextSource, content: String, truncated: Bool) {
        untrusted = true
        paneID = agent.paneID
        workspaceID = agent.workspaceID
        targetVersion = agent.targetVersion
        provider = agent.provider
        providerSessionID = agent.providerSessionID
        self.source = source
        capturedAt = Date()
        self.content = content
        byteCount = content.utf8.count
        self.truncated = truncated
    }
}
