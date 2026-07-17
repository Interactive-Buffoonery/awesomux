import Testing
@testable import awesoMux

@Suite("Window-order diagnostics")
struct WindowOrderDiagnosticsTests {
    @Test("diagnostics require the exact opt-in value")
    @MainActor
    func diagnosticsRequireExactOptIn() {
        #expect(WindowOrderDiagnostics.enabled(in: [:]) == false)
        #expect(WindowOrderDiagnostics.enabled(in: [WindowOrderDiagnostics.environmentKey: "0"]) == false)
        #expect(WindowOrderDiagnostics.enabled(in: [WindowOrderDiagnostics.environmentKey: "true"]) == false)
        #expect(WindowOrderDiagnostics.enabled(in: [WindowOrderDiagnostics.environmentKey: "1"]))
    }
}
