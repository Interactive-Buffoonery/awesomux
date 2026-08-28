import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

enum RemoteLivenessProbe {
    static let maximumOutputByteCount = RemoteForegroundLivenessReport.maximumEncodedByteCount
    static let timeout: Duration = .seconds(3)

    enum Failure: Error, Equatable {
        case malformedOutput
        case unsupportedVersion
    }

    static func decode(_ data: Data) throws -> RemoteForegroundLiveness {
        guard !data.isEmpty, data.count <= maximumOutputByteCount else {
            throw Failure.malformedOutput
        }
        let decoder = JSONDecoder()
        let report: RemoteForegroundLivenessReport
        do {
            report = try decoder.decode(RemoteForegroundLivenessReport.self, from: data)
        } catch {
            throw Failure.malformedOutput
        }
        guard report.v == RemoteForegroundLivenessReport.currentVersion else {
            throw Failure.unsupportedVersion
        }

        // JSONDecoder rejects startup text and a second object. Tighten its
        // whitespace tolerance to exactly one helper object plus one optional
        // LF, while allowing ordinary JSON key-order differences across Linux
        // and macOS encoders.
        let accepted = data.last == 0x0A ? Data(data.dropLast()) : data
        guard accepted.first == 0x7B, accepted.last == 0x7D else {
            throw Failure.malformedOutput
        }
        return RemoteForegroundLiveness(report.state)
    }

    static func run(
        command: String,
        exec: @escaping @Sendable (String, Duration, Int) async throws -> Data = { command, timeout, bound in
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command],
                input: .data(Data()),
                maximumOutputByteCount: bound,
                timeout: timeout
            )
        }
    ) async throws -> RemoteForegroundLiveness {
        try decode(try await exec(command, timeout, maximumOutputByteCount))
    }
}
