import Foundation

enum BridgeDoctorSignals {
    typealias ExecChannel = @Sendable (_ command: String, _ stdin: Data?) async throws -> Data

    /// Intersects the helper's `--version` output (one protocol per line)
    /// against the app's supported set. Empty result ⇒ incompatible. Garbage or
    /// empty output ⇒ empty intersection ⇒ fail-closed, never accepted.
    static func compatibleProtocols(
        helperVersionOutput: String,
        appSupported: Set<String>
    ) -> Set<String> {
        let advertised = helperVersionOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return appSupported.intersection(advertised)
    }
}
