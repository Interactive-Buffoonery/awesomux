import Testing
@testable import awesoMux

@Suite("GhosttySurfaceMouseButtonPolicy")
struct GhosttySurfaceMouseButtonPolicyTests {
    @Test("focus-only left click suppresses press and paired release")
    func focusOnlyLeftClickSuppressesPairedRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()
        policy.armFocusOnlyLeftClick()

        let press = policy.mouseDown(button: .left, surfaceIdentity: 1)
        let release = policy.mouseUp(button: .left, surfaceIdentity: 1)

        #expect(press == .suppress)
        #expect(release == .suppress)
        #expect(!policy.isFocusOnlyLeftClickArmed)
    }

    @Test("nil-surface cold-start press suppresses later surface release")
    func nilSurfacePressSuppressesLaterSurfaceRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .left, surfaceIdentity: nil)
        let release = policy.mouseUp(button: .left, surfaceIdentity: 1)

        #expect(press == .suppress)
        #expect(release == .suppress)
    }

    @Test("right-button nil-surface press suppresses paired release")
    func rightButtonNilSurfacePressSuppressesRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .right, surfaceIdentity: nil)
        let release = policy.mouseUp(button: .right, surfaceIdentity: 1)

        #expect(press == .suppress)
        #expect(release == .suppress)
    }

    @Test("other-button nil-surface press suppresses paired release")
    func otherButtonNilSurfacePressSuppressesRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .other, surfaceIdentity: nil)
        let release = policy.mouseUp(button: .other, surfaceIdentity: 1)

        #expect(press == .suppress)
        #expect(release == .suppress)
    }

    @Test("matching press and release surface identity sends release")
    func matchingSurfaceIdentitySendsRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .left, surfaceIdentity: 1)
        let release = policy.mouseUp(button: .left, surfaceIdentity: 1)

        #expect(press == .send)
        #expect(release == .send)
    }

    @Test("mismatched press and release surface identity suppresses release")
    func mismatchedSurfaceIdentitySuppressesRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .left, surfaceIdentity: 1)
        let release = policy.mouseUp(button: .left, surfaceIdentity: 2)

        #expect(press == .send)
        #expect(release == .suppress)
    }

    @Test("release with nil current surface is suppressed")
    func nilReleaseSurfaceSuppressesRelease() {
        var policy = GhosttySurfaceMouseButtonPolicy<Int>()

        let press = policy.mouseDown(button: .left, surfaceIdentity: 1)
        let release = policy.mouseUp(button: .left, surfaceIdentity: nil)

        #expect(press == .send)
        #expect(release == .suppress)
    }
}
