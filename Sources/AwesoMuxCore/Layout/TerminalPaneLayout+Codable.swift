import Foundation

public indirect enum TerminalPaneLayout: Hashable, Sendable {
    case pane(TerminalPane)
    case split(TerminalSplit)
    case documentGroup(DocumentGroup)
}

extension TerminalPaneLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case pane
        case split
        case documentGroup
        /// Legacy v3/v4 leaf (`.document(DocumentPane)`). Decode-only: it maps
        /// to a single-tab `DocumentGroup` so pre-INT-748 snapshots keep their
        /// tree shape. New encoders never write this key, so accepting it
        /// unconditionally (no version gate) can't misfire on future data.
        case document
    }

    private enum PayloadKeys: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Mirror the synthesized enum shape: exactly one case key, whose payload
        // sits under an "_0" wrapper.
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "TerminalPaneLayout must contain exactly one case key"
                )
            )
        }
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: key)
        switch key {
        case .pane:
            self = .pane(try payload.decode(TerminalPane.self, forKey: .value))
        case .split:
            self = .split(try payload.decode(TerminalSplit.self, forKey: .value))
        case .documentGroup:
            self = .documentGroup(try payload.decode(DocumentGroup.self, forKey: .value))
        case .document:
            let legacy = try payload.decode(DocumentPane.self, forKey: .value)
            self = .documentGroup(DocumentGroup(tabs: [legacy], selectedTabID: legacy.id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .pane)
            try payload.encode(pane, forKey: .value)
        case let .split(split):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .split)
            try payload.encode(split, forKey: .value)
        case let .documentGroup(group):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .documentGroup)
            try payload.encode(group, forKey: .value)
        }
    }
}
