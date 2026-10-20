import Foundation

/// A shell-integration completion with known status and measured runtime.
public struct ShellCommandCompletion: Sendable {
    public static let attentionThresholdNanoseconds: UInt64 = 30_000_000_000

    public let exitCode: Int
    public let durationNanoseconds: UInt64

    public init?(exitCode: Int16, durationNanoseconds: UInt64) {
        guard (0...255).contains(exitCode), durationNanoseconds > 0 else { return nil }
        self.exitCode = Int(exitCode)
        self.durationNanoseconds = durationNanoseconds
    }

    public var durationSeconds: Double { Double(durationNanoseconds) / 1_000_000_000 }
    public var attentionReason: String { exitCode == 0 ? "commandFinished" : "commandFailed" }
    public var warrantsAttention: Bool { durationNanoseconds > Self.attentionThresholdNanoseconds }
}
