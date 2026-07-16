import AppKit
import Testing
@testable import awesoMux

@Suite("AwesoMux window roles")
struct AwesoMuxWindowRoleTests {
    private final class MainCapableWindow: NSWindow {
        override var canBecomeMain: Bool { true }
    }

    @MainActor
    private final class PrimaryWindowState {
        var isAvailable = false
    }

    // The NSWindow extension feeds real AppKit facts into this predicate at
    // runtime; keeping the tests on the pure table avoids constructing hidden
    // AppKit windows inside the SwiftPM testing helper.
    @Test("unmarked main-capable windows are not primary content")
    func unmarkedMainCapableWindowIsNotPrimaryContent() {
        #expect(
            !AwesoMuxWindowRole.isPrimaryContentEligible(
                role: nil,
                isPanel: false,
                canBecomeMain: true
            ))
    }

    @Test("primary content role marks a normal window as primary-eligible")
    func primaryContentWindowIsEligible() {
        #expect(
            AwesoMuxWindowRole.isPrimaryContentEligible(
                role: .primaryContent,
                isPanel: false,
                canBecomeMain: true
            ))
    }

    @Test("primary content role still requires main capability")
    func primaryContentWindowStillRequiresMainCapability() {
        #expect(
            !AwesoMuxWindowRole.isPrimaryContentEligible(
                role: .primaryContent,
                isPanel: false,
                canBecomeMain: false
            ))
    }

    @Test("settings role is never primary-eligible")
    func settingsWindowIsNotEligible() {
        #expect(
            !AwesoMuxWindowRole.isPrimaryContentEligible(
                role: .settings,
                isPanel: false,
                canBecomeMain: true
            ))
    }

    @Test("panels are not primary-eligible even when marked primary")
    func panelMarkedPrimaryContentIsNotEligible() {
        #expect(
            !AwesoMuxWindowRole.isPrimaryContentEligible(
                role: .primaryContent,
                isPanel: true,
                canBecomeMain: true
            ))
    }

    @Test("clearing the role makes a window non-primary again")
    func clearingRoleMakesWindowNonPrimary() {
        var role: AwesoMuxWindowRole? = .primaryContent
        #expect(
            AwesoMuxWindowRole.isPrimaryContentEligible(
                role: role,
                isPanel: false,
                canBecomeMain: true
            ))

        role = nil
        #expect(
            !AwesoMuxWindowRole.isPrimaryContentEligible(
                role: role,
                isPanel: false,
                canBecomeMain: true
            ))
    }

    @Test("settings main and panel key still resolve the available primary content window")
    @MainActor
    func distractingWindowsDoNotReplacePrimaryContent() {
        let content = MainCapableWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        content.awesoMuxWindowRole = .primaryContent
        let settings = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        settings.awesoMuxWindowRole = .settings
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.awesoMuxWindowRole = .primaryContent

        let resolved = AwesoMuxWindowRole.primaryContentWindow(
            mainWindow: settings,
            keyWindow: panel,
            windows: [settings, panel, content],
            isVisible: { _ in true }
        )

        #expect(resolved === content)
    }

    @Test("settings alone does not provide a sidebar command target")
    @MainActor
    func settingsAloneDoesNotProvideSidebarCommandTarget() {
        let settings = MainCapableWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        settings.awesoMuxWindowRole = .settings

        let resolved = AwesoMuxWindowRole.primaryContentWindow(
            mainWindow: settings,
            keyWindow: settings,
            windows: [settings],
            isVisible: { _ in true }
        )

        #expect(resolved == nil)
    }

    @Test("sidebar command target availability follows role and close events")
    @MainActor
    func sidebarCommandTargetAvailabilityFollowsLifecycle() {
        let center = NotificationCenter()
        let closingWindow = MainCapableWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let state = PrimaryWindowState()
        let availability = SidebarCommandTargetAvailability(
            notificationCenter: center,
            resolve: { excludedWindow in
                state.isAvailable && excludedWindow !== closingWindow
            }
        )
        #expect(!availability.isAvailable)

        state.isAvailable = true
        center.post(name: .awesoMuxWindowRoleDidChange, object: closingWindow)
        #expect(availability.isAvailable)

        center.post(name: NSWindow.willCloseNotification, object: closingWindow)
        #expect(!availability.isAvailable)
    }
}
