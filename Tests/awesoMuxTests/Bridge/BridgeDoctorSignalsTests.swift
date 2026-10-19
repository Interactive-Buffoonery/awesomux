import Testing
@testable import awesoMux

@Suite("Bridge doctor signals")
struct BridgeDoctorSignalsTests {
    @Test(
        "version intersection is fail-closed on garbage/empty and matches on a supported line",
        arguments: [
            ("awesomux-bridge-v1", true),
            ("future-v2", false),
            ("!!garbage??", false),
            ("", false),
            ("   \n   ", false),
            ("  awesomux-bridge-v1  \nfuture-v2", true),
        ]
    )
    func versionIntersection(output: String, compatible: Bool) {
        let result = BridgeDoctorSignals.compatibleProtocols(
            helperVersionOutput: output,
            appSupported: ["awesomux-bridge-v1"]
        )
        #expect(result.isEmpty == !compatible)
    }
}
