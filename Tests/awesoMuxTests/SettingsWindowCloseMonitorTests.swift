import AppKit
import Testing
@testable import awesoMux

@Suite("Settings window close monitor")
@MainActor
struct SettingsWindowCloseMonitorTests {
    @Test("Closing the observed window reports closure")
    func observedWindowCloseReportsClosure() {
        let center = NotificationCenter()
        let window = NSWindow()
        var closeCount = 0
        let monitor = SettingsWindowCloseMonitor(notificationCenter: center) {
            closeCount += 1
        }
        monitor.observe(window)

        center.post(name: NSWindow.willCloseNotification, object: window)

        #expect(closeCount == 1)
    }

    @Test("Closing another window is inert")
    func otherWindowCloseIsInert() {
        let center = NotificationCenter()
        let observedWindow = NSWindow()
        let otherWindow = NSWindow()
        var closeCount = 0
        let monitor = SettingsWindowCloseMonitor(notificationCenter: center) {
            closeCount += 1
        }
        monitor.observe(observedWindow)

        center.post(name: NSWindow.willCloseNotification, object: otherWindow)

        #expect(closeCount == 0)
    }

    @Test("Replacing the observed window retires the old observation")
    func replacingWindowRetiresOldObservation() {
        let center = NotificationCenter()
        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        var closeCount = 0
        let monitor = SettingsWindowCloseMonitor(notificationCenter: center) {
            closeCount += 1
        }
        monitor.observe(oldWindow)
        monitor.observe(newWindow)

        center.post(name: NSWindow.willCloseNotification, object: oldWindow)
        center.post(name: NSWindow.willCloseNotification, object: newWindow)

        #expect(closeCount == 1)
    }
}
