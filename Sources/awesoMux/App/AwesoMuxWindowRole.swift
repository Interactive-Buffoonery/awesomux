import AppKit
import Observation
import ObjectiveC

extension Notification.Name {
    static let awesoMuxWindowRoleDidChange = Notification.Name(
        "com.interactivebuffoonery.awesomux.windowRoleDidChange"
    )
}

enum AwesoMuxWindowRole: String {
    case primaryContent
    case settings
    case about

    /// Auxiliary scene windows (Settings, About) that a global close command
    /// should close directly rather than routing into pane/workspace teardown.
    /// Fail-closed: an unclassified window (`nil`, or the primary content
    /// window) is NOT an auxiliary target, so Cmd-W keeps its normal
    /// pane-close behaviour when the role can't be determined.
    static func isAuxiliaryCloseTarget(_ role: AwesoMuxWindowRole?) -> Bool {
        switch role {
        case .settings, .about: return true
        case .primaryContent, .none: return false
        }
    }

    static func isPrimaryContentEligible(
        role: AwesoMuxWindowRole?,
        isPanel: Bool,
        canBecomeMain: Bool
    ) -> Bool {
        role == .primaryContent && !isPanel && canBecomeMain
    }

    @MainActor
    static func primaryContentWindow(
        mainWindow: NSWindow?,
        keyWindow: NSWindow?,
        windows: [NSWindow],
        isVisible: (NSWindow) -> Bool = { $0.isVisible }
    ) -> NSWindow? {
        for preferredWindow in [mainWindow, keyWindow].compactMap({ $0 })
        where isVisible(preferredWindow) && preferredWindow.isAwesoMuxPrimaryContentWindow {
            return preferredWindow
        }
        return windows.first { window in
            isVisible(window) && window.isAwesoMuxPrimaryContentWindow
        }
    }
}

@MainActor
enum SidebarCommandTarget {
    static func isAvailable(
        in application: NSApplication = .shared,
        excluding excludedWindow: NSWindow? = nil
    ) -> Bool {
        let mainWindow = application.mainWindow === excludedWindow ? nil : application.mainWindow
        let keyWindow = application.keyWindow === excludedWindow ? nil : application.keyWindow
        let windows = application.windows.filter { $0 !== excludedWindow }
        return AwesoMuxWindowRole.primaryContentWindow(
            mainWindow: mainWindow,
            keyWindow: keyWindow,
            windows: windows
        ) != nil
    }
}

@Observable
@MainActor
final class SidebarCommandTargetAvailability {
    private(set) var isAvailable: Bool

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let resolve: @MainActor (NSWindow?) -> Bool
    @ObservationIgnored nonisolated(unsafe) private var observations: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        resolve: @MainActor @escaping (NSWindow?) -> Bool = {
            SidebarCommandTarget.isAvailable(excluding: $0)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.resolve = resolve
        isAvailable = resolve(nil)

        for name in [
            .awesoMuxWindowRoleDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didResignMainNotification,
            NSWindow.willCloseNotification,
        ] {
            observations.append(
                notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    nonisolated(unsafe) let notification = notification
                    MainActor.assumeIsolated {
                        let excludedWindow =
                            notification.name == NSWindow.willCloseNotification
                            ? notification.object as? NSWindow
                            : nil
                        self?.refresh(excluding: excludedWindow)
                    }
                })
        }
    }

    isolated deinit {
        observations.forEach(notificationCenter.removeObserver)
    }

    func refresh(excluding excludedWindow: NSWindow? = nil) {
        isAvailable = resolve(excludedWindow)
    }
}

private final class AwesoMuxWindowRoleAssociationKey: @unchecked Sendable {}

private enum AwesoMuxWindowRoleAssociation {
    static let key = AwesoMuxWindowRoleAssociationKey()

    static var pointer: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(key).toOpaque())
    }
}

extension NSWindow {
    @MainActor
    var awesoMuxWindowRole: AwesoMuxWindowRole? {
        get {
            guard
                let rawValue = objc_getAssociatedObject(
                    self,
                    AwesoMuxWindowRoleAssociation.pointer
                ) as? NSString
            else {
                return nil
            }

            return AwesoMuxWindowRole(rawValue: rawValue as String)
        }
        set {
            let previousRole = awesoMuxWindowRole
            objc_setAssociatedObject(
                self,
                AwesoMuxWindowRoleAssociation.pointer,
                newValue?.rawValue as NSString?,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
            if previousRole != newValue {
                NotificationCenter.default.post(
                    name: .awesoMuxWindowRoleDidChange,
                    object: self
                )
            }
        }
    }

    @MainActor
    var isAwesoMuxPrimaryContentWindow: Bool {
        AwesoMuxWindowRole.isPrimaryContentEligible(
            role: awesoMuxWindowRole,
            isPanel: self is NSPanel,
            canBecomeMain: canBecomeMain
        )
    }
}

extension NSApplication {
    /// The window floating companions anchor to. `mainWindow`/`keyWindow` can
    /// be a panel or Settings at toggle time, which would mis-anchor the
    /// companion and leave its move observers on the wrong window.
    @MainActor
    var awesoMuxPrimaryContentWindow: NSWindow? {
        AwesoMuxWindowRole.primaryContentWindow(
            mainWindow: mainWindow,
            keyWindow: keyWindow,
            windows: windows
        )
    }
}
