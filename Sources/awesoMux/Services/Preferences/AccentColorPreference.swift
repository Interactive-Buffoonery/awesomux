import SwiftUI

enum AccentColorPreference: String, CaseIterable, Identifiable {
    case peach
    case mauve
    case sapphire
    case green

    var id: Self { self }

    var title: String {
        switch self {
        case .peach: "Peach"
        case .mauve: "Mauve"
        case .sapphire: "Sapphire"
        case .green: "Green"
        }
    }

    var color: Color {
        switch self {
        case .peach: Color(.sRGB, red: 0.98, green: 0.70, blue: 0.53, opacity: 1)
        case .mauve: Color(.sRGB, red: 0.80, green: 0.65, blue: 0.96, opacity: 1)
        case .sapphire: Color(.sRGB, red: 0.45, green: 0.78, blue: 0.92, opacity: 1)
        case .green: Color(.sRGB, red: 0.65, green: 0.89, blue: 0.63, opacity: 1)
        }
    }
}
