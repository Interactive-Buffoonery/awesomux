import AwesoMuxConfig
import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case mocha
    case latte

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .mocha: "Mocha"
        case .latte: "Latte"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .mocha: .dark
        case .latte: .light
        }
    }
}

extension AppearanceConfig.Theme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
