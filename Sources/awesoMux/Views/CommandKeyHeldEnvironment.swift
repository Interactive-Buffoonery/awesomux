import AppKit
import SwiftUI

private struct IsCommandKeyHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the ⌘ modifier is held and the app is active. Set by
    /// `trackingCommandKeyHeld` on the collapsed rail; read by tiles to
    /// reveal jump numbers. Defaults to false everywhere else.
    var isCommandKeyHeld: Bool {
        get { self[IsCommandKeyHeldKey.self] }
        set { self[IsCommandKeyHeldKey.self] = newValue }
    }
}

/// Installs a local `flagsChanged` monitor while attached, mirroring the ⌘
/// state into a binding. Scope it to the collapsed rail so the monitor isn't
/// alive when the rail is expanded. Local monitors only see events while the
/// app is active, which is exactly when the reveal matters.
private struct CommandKeyHeldMonitor: ViewModifier {
    @Binding var isHeld: Bool
    @State private var monitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear {
                // SwiftUI can re-run onAppear without an intervening onDisappear
                // on identity-preserving transitions, so guard against installing
                // a second monitor and leaking the first.
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let held = event.modifierFlags.contains(.command)
                    guard held != isHeld else { return event }
                    // flagsChanged local monitors fire on the main thread, so
                    // mutating the bound state directly here is safe.
                    if reduceMotion {
                        isHeld = held
                    } else {
                        withAnimation(.easeOut(duration: 0.10)) {
                            isHeld = held
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
                isHeld = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                isHeld = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // flagsChanged fires on transitions, not on focus return — so a
                // user who ⌘-tabbed away and back while still holding ⌘ would see
                // no reveal until they re-press. Resync from the live flags.
                let held = NSEvent.modifierFlags.contains(.command)
                if held != isHeld {
                    isHeld = held
                }
            }
    }
}

extension View {
    func trackingCommandKeyHeld(_ isHeld: Binding<Bool>) -> some View {
        modifier(CommandKeyHeldMonitor(isHeld: isHeld))
    }
}
