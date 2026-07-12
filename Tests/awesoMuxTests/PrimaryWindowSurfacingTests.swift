import Testing
@testable import awesoMux

@Suite("Primary window surfacing")
struct PrimaryWindowSurfacingTests {
    @Test("existing primary window orders front")
    func existingPrimaryWindowOrdersFront() {
        var didDeminiaturize = 0
        var didOrderFront = 0
        var didOpenPrimary = 0
        var didBeep = 0

        PrimaryWindowSurfacer.surface(
            window: PrimaryWindowSurfaceWindow(
                isMiniaturized: false,
                deminiaturize: { didDeminiaturize += 1 },
                orderFront: { didOrderFront += 1 }
            ),
            openPrimaryWindow: { didOpenPrimary += 1 },
            beep: { didBeep += 1 }
        )

        #expect(didDeminiaturize == 0)
        #expect(didOrderFront == 1)
        #expect(didOpenPrimary == 0)
        #expect(didBeep == 0)
    }

    @Test("miniaturized primary window deminiaturizes before ordering front")
    func miniaturizedPrimaryWindowDeminiaturizes() {
        var calls: [String] = []

        PrimaryWindowSurfacer.surface(
            window: PrimaryWindowSurfaceWindow(
                isMiniaturized: true,
                deminiaturize: { calls.append("deminiaturize") },
                orderFront: { calls.append("orderFront") }
            ),
            openPrimaryWindow: { calls.append("openPrimary") },
            beep: { calls.append("beep") }
        )

        #expect(calls == ["deminiaturize", "orderFront"])
    }

    @Test("missing primary window opens the primary scene once")
    func missingPrimaryWindowOpensPrimarySceneOnce() {
        var didOpenPrimary = 0
        var didBeep = 0

        PrimaryWindowSurfacer.surface(
            window: nil,
            openPrimaryWindow: { didOpenPrimary += 1 },
            beep: { didBeep += 1 }
        )

        #expect(didOpenPrimary == 1)
        #expect(didBeep == 0)
    }

    @Test("missing primary window without open action beeps")
    func missingPrimaryWindowWithoutOpenActionBeeps() {
        var didBeep = 0

        PrimaryWindowSurfacer.surface(
            window: nil,
            openPrimaryWindow: nil,
            beep: { didBeep += 1 }
        )

        #expect(didBeep == 1)
    }
}
