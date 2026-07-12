/// Supplies the value a `@TOMLDefault` field falls back to when its key is
/// absent from the decoded TOML. This is the hook that lets a hand-edited or
/// older config omit a key and still decode — replacing the per-struct
/// `init(from:)` boilerplate that otherwise has to repeat
/// `decodeIfPresent(...) ?? default` for every single field.
public protocol DefaultProvider {
    associatedtype Value: Codable & Equatable & Sendable
    static var defaultValue: Value { get }
}

/// Property wrapper that makes a `Codable` field tolerate a missing key by
/// decoding to `Provider.defaultValue` instead of throwing `keyNotFound`.
///
/// Why this exists: Swift's *synthesized* `init(from:)` ignores a stored
/// property's default value — `var x = false` still throws when the key is
/// absent. Config files here are user-editable and version-skewed, so a
/// missing key must default, not crash. The historical fix was a hand-written
/// `init(from:)` per struct, which meant every new field lived in five places
/// and a forgotten line shipped a self-bricking decode. `@TOMLDefault` collapses
/// that to one annotation and deletes the hand-written decoder.
///
/// The load-bearing piece is the `KeyedDecodingContainer` overload below.
@propertyWrapper
public struct TOMLDefault<Provider: DefaultProvider>: Codable, Equatable, Sendable {
    public var wrappedValue: Provider.Value

    public init(wrappedValue: Provider.Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = try container.decode(Provider.Value.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

public extension KeyedDecodingContainer {
    /// Resolves when a struct's synthesized `Decodable` calls
    /// `container.decode(TOMLDefault<P>.self, forKey:)`. A present key decodes
    /// normally; a *missing* key returns `P.defaultValue` rather than throwing.
    /// This single overload is what makes one `@TOMLDefault` annotation behave
    /// like the old hand-written `decodeIfPresent(...) ?? default`.
    ///
    /// This is a module-global overload (it participates in overload resolution
    /// for every `Decodable` in any module importing `AwesoMuxConfig`), but it
    /// only ever matches the concrete `TOMLDefault<P>` type — any other type
    /// falls through to the stdlib `decode`. A *present but wrong-typed* value
    /// still throws (only an absent key defaults), which keeps a garbled value
    /// fail-closed rather than silently snapping to the default.
    func decode<P>(_ type: TOMLDefault<P>.Type, forKey key: Key) throws -> TOMLDefault<P> {
        try decodeIfPresent(type, forKey: key) ?? TOMLDefault(wrappedValue: P.defaultValue)
    }
}

private protocol AnyOptional {
    var isNil: Bool { get }
}

extension Optional: AnyOptional {
    var isNil: Bool { self == nil }
}

extension KeyedEncodingContainer {
    /// Omits the key when a wrapped Optional is nil — TOML has no null, so
    /// without this a `@TOMLDefault var x: String?` at nil would fail encode.
    mutating func encode<P>(_ value: TOMLDefault<P>, forKey key: Key) throws {
        if let optional = value.wrappedValue as? any AnyOptional, optional.isNil {
            return
        }
        try encode(value.wrappedValue, forKey: key)
    }
}
