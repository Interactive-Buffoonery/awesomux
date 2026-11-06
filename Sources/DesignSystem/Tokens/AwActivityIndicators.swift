import SwiftUI

private struct AwAnimateAgentSpinnersKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var awAnimateAgentSpinners: Bool {
        get { self[AwAnimateAgentSpinnersKey.self] }
        set { self[AwAnimateAgentSpinnersKey.self] = newValue }
    }
}
