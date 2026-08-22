import Testing
@testable import awesoMux

@MainActor
@Suite("ShortcutDiagnostics cap ordering")
struct ShortcutDiagnosticsCapTests {
    @Test("a record landing exactly on the cap is allowed")
    func recordLandingOnCapAllowed() {
        #expect(
            !ShortcutDiagnostics.recordWouldCrossCap(
                totalWritten: ShortcutDiagnostics.maxTotalBytes - 10,
                incomingBytes: 10
            )
        )
    }

    @Test("a record that would cross the cap is stopped")
    func recordCrossingCapStopped() {
        #expect(
            ShortcutDiagnostics.recordWouldCrossCap(
                totalWritten: ShortcutDiagnostics.maxTotalBytes - 10,
                incomingBytes: 11
            )
        )
        #expect(
            ShortcutDiagnostics.recordWouldCrossCap(
                totalWritten: ShortcutDiagnostics.maxTotalBytes,
                incomingBytes: 1
            )
        )
    }
}
