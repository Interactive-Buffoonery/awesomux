enum TerminalPanelCloseTarget: Equatable {
    case popUp
    case floating
    case none
}

enum TerminalPanelCommandRouter {
    static func target(
        popUpIsKey: Bool,
        floatingIsKey: Bool,
        popUpIsVisible: Bool,
        floatingIsVisible: Bool,
        popUpOrder: Int?,
        floatingOrder: Int?
    ) -> TerminalPanelCloseTarget {
        if popUpIsKey { return .popUp }
        if floatingIsKey { return .floating }
        if popUpIsVisible, floatingIsVisible {
            return (popUpOrder ?? .max) <= (floatingOrder ?? .max) ? .popUp : .floating
        }
        if popUpIsVisible { return .popUp }
        if floatingIsVisible { return .floating }
        return .none
    }
}
