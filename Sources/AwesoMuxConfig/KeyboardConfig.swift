public struct KeyboardConfig: Codable, Equatable, Sendable {
    @TOMLDefault<ShortcutBindingsDefault> public var shortcuts: [String: ShortcutBindingConfig]

    public static let defaultValue = KeyboardConfig()

    public init(shortcuts: [String: ShortcutBindingConfig] = [:]) {
        self._shortcuts = TOMLDefault(wrappedValue: shortcuts)
    }
}

public struct ShortcutBindingConfig: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [ShortcutModifier]

    public init(key: String, modifiers: [ShortcutModifier]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum ShortcutModifier: String, Codable, CaseIterable, Equatable, Sendable {
    case control
    case option
    case shift
    case command
}

public enum ShortcutBindingsDefault: DefaultProvider {
    public static let defaultValue: [String: ShortcutBindingConfig] = [:]
}
