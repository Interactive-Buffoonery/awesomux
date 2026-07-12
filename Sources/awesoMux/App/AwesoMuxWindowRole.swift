import AppKit
import ObjectiveC

enum AwesoMuxWindowRole: String {
    case primaryContent
    case settings

    static func isPrimaryContentEligible(
        role: AwesoMuxWindowRole?,
        isPanel: Bool,
        canBecomeMain: Bool
    ) -> Bool {
        role == .primaryContent && !isPanel && canBecomeMain
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
            guard let rawValue = objc_getAssociatedObject(
                self,
                AwesoMuxWindowRoleAssociation.pointer
            ) as? NSString else {
                return nil
            }

            return AwesoMuxWindowRole(rawValue: rawValue as String)
        }
        set {
            objc_setAssociatedObject(
                self,
                AwesoMuxWindowRoleAssociation.pointer,
                newValue?.rawValue as NSString?,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
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
        if let main = mainWindow,
           main.isVisible,
           main.isAwesoMuxPrimaryContentWindow {
            return main
        }
        return windows.first { window in
            window.isVisible && window.isAwesoMuxPrimaryContentWindow
        }
    }
}
