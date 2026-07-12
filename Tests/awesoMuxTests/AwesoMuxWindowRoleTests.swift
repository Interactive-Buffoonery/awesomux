import Testing
@testable import awesoMux

@Suite("AwesoMux window roles")
struct AwesoMuxWindowRoleTests {
    // The NSWindow extension feeds real AppKit facts into this predicate at
    // runtime; keeping the tests on the pure table avoids constructing hidden
    // AppKit windows inside the SwiftPM testing helper.
    @Test("unmarked main-capable windows are not primary content")
    func unmarkedMainCapableWindowIsNotPrimaryContent() {
        #expect(!AwesoMuxWindowRole.isPrimaryContentEligible(
            role: nil,
            isPanel: false,
            canBecomeMain: true
        ))
    }

    @Test("primary content role marks a normal window as primary-eligible")
    func primaryContentWindowIsEligible() {
        #expect(AwesoMuxWindowRole.isPrimaryContentEligible(
            role: .primaryContent,
            isPanel: false,
            canBecomeMain: true
        ))
    }

    @Test("primary content role still requires main capability")
    func primaryContentWindowStillRequiresMainCapability() {
        #expect(!AwesoMuxWindowRole.isPrimaryContentEligible(
            role: .primaryContent,
            isPanel: false,
            canBecomeMain: false
        ))
    }

    @Test("settings role is never primary-eligible")
    func settingsWindowIsNotEligible() {
        #expect(!AwesoMuxWindowRole.isPrimaryContentEligible(
            role: .settings,
            isPanel: false,
            canBecomeMain: true
        ))
    }

    @Test("panels are not primary-eligible even when marked primary")
    func panelMarkedPrimaryContentIsNotEligible() {
        #expect(!AwesoMuxWindowRole.isPrimaryContentEligible(
            role: .primaryContent,
            isPanel: true,
            canBecomeMain: true
        ))
    }

    @Test("clearing the role makes a window non-primary again")
    func clearingRoleMakesWindowNonPrimary() {
        var role: AwesoMuxWindowRole? = .primaryContent
        #expect(AwesoMuxWindowRole.isPrimaryContentEligible(
            role: role,
            isPanel: false,
            canBecomeMain: true
        ))

        role = nil
        #expect(!AwesoMuxWindowRole.isPrimaryContentEligible(
            role: role,
            isPanel: false,
            canBecomeMain: true
        ))
    }
}
