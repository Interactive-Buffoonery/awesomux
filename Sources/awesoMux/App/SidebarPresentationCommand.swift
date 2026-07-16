import Foundation
import Observation

struct SidebarPresentationCommand: Equatable, Sendable {
    let id: UUID
    let isHidden: Bool
    let shouldFocusSidebar: Bool
}

@Observable
@MainActor
final class SidebarPresentationCommandMailbox {
    private(set) var pending: SidebarPresentationCommand?

    @discardableResult
    func requestFocus(id: UUID = UUID()) -> SidebarPresentationCommand {
        replacePending(
            id: id,
            isHidden: false,
            shouldFocusSidebar: true)
    }

    @discardableResult
    func requestVisibilityToggle(
        currentIsHidden: Bool,
        id: UUID = UUID()
    ) -> SidebarPresentationCommand {
        replacePending(
            id: id,
            isHidden: !(pending?.isHidden ?? currentIsHidden),
            shouldFocusSidebar: false)
    }

    @discardableResult
    func acknowledge(id: UUID) -> Bool {
        guard pending?.id == id else { return false }
        pending = nil
        return true
    }

    private func replacePending(
        id: UUID,
        isHidden: Bool,
        shouldFocusSidebar: Bool
    ) -> SidebarPresentationCommand {
        let command = SidebarPresentationCommand(
            id: id,
            isHidden: isHidden,
            shouldFocusSidebar: shouldFocusSidebar)
        pending = command
        return command
    }
}
