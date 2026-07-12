import Foundation

public struct SyntheticSessionTitle: Codable, Hashable, Sendable {
    public let agentKind: AgentKind
    public let index: Int

    public init(agentKind: AgentKind, index: Int) {
        precondition(index > 0, "Synthetic session title indices must be positive")
        self.agentKind = agentKind
        self.index = index
    }

    public var canonicalTitle: String {
        "\(canonicalPrefix) \(index)"
    }

    public func localizedTitle(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let name: String
        if agentKind == .shell {
            name = String(
                localized: "shell",
                bundle: bundle,
                locale: locale,
                comment: "Fallback workspace title noun for an unnamed shell workspace."
            )
        } else {
            name = agentKind.localizedShortName(bundle: bundle, locale: locale)
        }
        let format = String(
            localized: "%1$@ %2$lld",
            bundle: bundle,
            locale: locale,
            comment: "Generated title for an unnamed workspace. Arguments are the agent or shell name and a positive index."
        )
        return String(format: format, locale: locale, arguments: [name, index])
    }

    static func inferred(from title: String, preferredAgentKind: AgentKind) -> Self? {
        let candidateKinds = [preferredAgentKind]
            + AgentKind.allCases.filter { $0 != preferredAgentKind }
        return candidateKinds.compactMap { inferred(from: title, agentKind: $0) }.first
    }

    private static func inferred(from title: String, agentKind: AgentKind) -> Self? {
        let prefix = agentKind == .shell ? "shell" : agentKind.shortName
        let expectedPrefix = prefix + " "
        guard title.hasPrefix(expectedPrefix),
              let index = Int(title.dropFirst(expectedPrefix.count)),
              index > 0 else {
            return nil
        }
        let candidate = Self(agentKind: agentKind, index: index)
        return title == candidate.canonicalTitle ? candidate : nil
    }

    private var canonicalPrefix: String {
        agentKind == .shell ? "shell" : agentKind.shortName
    }

    private enum CodingKeys: String, CodingKey {
        case agentKind
        case index
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Int.self, forKey: .index)
        guard index > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "Synthetic session title index must be positive"
            )
        }
        self.agentKind = try container.decode(AgentKind.self, forKey: .agentKind)
        self.index = index
    }
}
