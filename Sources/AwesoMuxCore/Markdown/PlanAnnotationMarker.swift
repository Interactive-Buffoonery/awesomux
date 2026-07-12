// Sources/AwesoMuxCore/Markdown/PlanAnnotationMarker.swift
//
// Single-marker codec for the AMX plan-annotation format defined in
// docs/plan-annotations.md. This layer knows nothing about documents, anchors,
// or <mark> pairing — it parses and serializes one HTML-comment marker.
// AttributedMarkdownBuilder decides anchor type from marker position; the
// writer layer composes these into guarded file edits.

import Foundation

// MARK: - Field vocabulary

/// The `by=` author of an annotation or thread note. Values are the exact
/// runtime provider identifiers plus `user`; there is deliberately no generic
/// "agent" case (INT-580 provider scope). A marker with an unrecognized author
/// fails to parse and stays an ordinary, invisible HTML comment.
public enum PlanAnnotationAuthor: String, Equatable, Sendable, CaseIterable {
    case user
    case claudeCode = "claude-code"
    case codex
    case pi
    case opencode
}

/// The `intent=` of an annotation. An unrecognized value parses as `.comment`
/// so a future intent degrades to a readable note instead of vanishing.
public enum PlanAnnotationIntent: String, Equatable, Sendable {
    case comment
    case replace
    case delete
}

/// The `status=` of an annotation. An unrecognized value parses as `.open`
/// (contract rule: future lifecycle states must not hide an annotation).
public enum PlanAnnotationStatus: String, Equatable, Sendable {
    case open
    case resolved
}

// MARK: - Marker

/// One parsed `<!-- AMX … -->` marker.
public enum PlanAnnotationMarker: Equatable, Sendable {
    case annotation(Annotation)
    case note(Note)

    /// A `key=value` pair the parser did not recognize. Preserved in order on
    /// rewrite so a newer schema's fields survive a round trip through an
    /// older build (contract: unknown keys are forward compatibility).
    public struct ExtraKey: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public struct Annotation: Equatable, Sendable {
        public var id: String
        public var author: PlanAnnotationAuthor
        public var intent: PlanAnnotationIntent { didSet { rawIntent = nil } }
        public var status: PlanAnnotationStatus { didSet { rawStatus = nil } }
        public var payload: String
        public var extraKeys: [ExtraKey]
        /// Raw `intent=`/`status=` values the parser did not recognize. Kept so
        /// a rewrite re-emits a future schema's value verbatim (same
        /// forward-compat stance as ExtraKey); display still degrades to
        /// comment/open. Assigning a known value clears the raw one.
        public private(set) var rawIntent: String?
        public private(set) var rawStatus: String?

        public init(
            id: String,
            author: PlanAnnotationAuthor,
            intent: PlanAnnotationIntent = .comment,
            status: PlanAnnotationStatus = .open,
            payload: String,
            extraKeys: [ExtraKey] = [],
            rawIntent: String? = nil,
            rawStatus: String? = nil
        ) {
            self.id = id
            self.author = author
            self.intent = intent
            self.status = status
            self.payload = payload
            self.extraKeys = extraKeys
            self.rawIntent = rawIntent
            self.rawStatus = rawStatus
        }
    }

    public struct Note: Equatable, Sendable {
        /// The id of the annotation this note replies to (`re=`).
        public var annotationID: String
        public var author: PlanAnnotationAuthor
        public var payload: String
        public var extraKeys: [ExtraKey]

        public init(
            annotationID: String,
            author: PlanAnnotationAuthor,
            payload: String,
            extraKeys: [ExtraKey] = []
        ) {
            self.annotationID = annotationID
            self.author = author
            self.payload = payload
            self.extraKeys = extraKeys
        }
    }
}

// MARK: - Parsing

extension PlanAnnotationMarker {
    /// Payloads past this size fail to parse (the marker stays an inert
    /// comment). A hostile or runaway writer must not buy an unbounded
    /// SwiftUI layout or a minutes-long VoiceOver read with one marker line.
    public static let maxPayloadBytes = 8192

    /// Parse a full `<!-- AMX … -->` comment. Returns nil for anything that is
    /// not a well-formed AMX marker — including unknown authors, malformed
    /// keys, and oversized payloads — so such comments stay inert instead of
    /// surfacing half-parsed.
    public static func parse(_ comment: String) -> PlanAnnotationMarker? {
        let trimmed = comment.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        let inner = trimmed.dropFirst(4).dropLast(3)
        // Prefix is case-sensitive: the writer only emits uppercase `AMX`, and a
        // strict match keeps prose like "<!-- amx notes below -->" out of the schema.
        guard inner.hasPrefix(" AMX "), inner.hasSuffix(" ") else { return nil }
        let rest = inner.dropFirst(" AMX ".count)

        let keysPart: Substring
        let rawPayload: String
        if let delimiter = rest.range(of: ": ") {
            keysPart = rest[rest.startIndex ..< delimiter.lowerBound]
            rawPayload = delimiter.upperBound == rest.endIndex
                ? ""
                : String(rest[delimiter.upperBound ..< rest.index(before: rest.endIndex)])
        } else {
            guard !rest.contains(":") else { return nil }
            keysPart = rest[..<rest.index(before: rest.endIndex)]
            rawPayload = ""
        }

        guard rawPayload.utf8.count <= Self.maxPayloadBytes else { return nil }

        var id: String?
        var re: String?
        var author: PlanAnnotationAuthor?
        var intent: PlanAnnotationIntent?
        var status: PlanAnnotationStatus?
        var rawIntent: String?
        var rawStatus: String?
        var usesLineEncoding = false
        var extras: [ExtraKey] = []

        for token in keysPart.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let eq = token.firstIndex(of: "=") else { return nil }
            let key = String(token[token.startIndex ..< eq])
            let value = String(token[token.index(after: eq)...])
            guard Self.isKey(key), Self.isToken(value) else { return nil }
            // For KNOWN keys the first occurrence wins, matching the render
            // model's first-writer-wins stance. Unknown keys are all preserved
            // — including duplicates — so a future schema's repeated field
            // survives a rewrite through this build (adversarial review).
            switch key {
            case "id": if id == nil {
                    id = value
                }
            case "re": if re == nil {
                    re = value
                }
            case "by":
                guard PlanAnnotationAuthor(rawValue: value) != nil else { return nil }
                if author == nil {
                    author = PlanAnnotationAuthor(rawValue: value)
                }
            case "intent": if intent == nil {
                    // Unknown values degrade for display but keep the raw text
                    // so a rewrite re-emits them (rewrite-compatibility).
                    intent = PlanAnnotationIntent(rawValue: value) ?? .comment
                    if PlanAnnotationIntent(rawValue: value) == nil { rawIntent = value }
                }
            case "status": if status == nil {
                    status = PlanAnnotationStatus(rawValue: value) ?? .open
                    if PlanAnnotationStatus(rawValue: value) == nil { rawStatus = value }
                }
            case "encoding":
                if value == "lines" {
                    usesLineEncoding = true
                } else {
                    extras.append(ExtraKey(key: key, value: value))
                }
            default: extras.append(ExtraKey(key: key, value: value))
            }
        }
        let resolvedIntent = intent ?? .comment
        let resolvedStatus = status ?? .open
        let payload = Self.desanitize(rawPayload, usesLineEncoding: usesLineEncoding)
        guard payload.utf8.count <= Self.maxPayloadBytes else { return nil }

        guard let author else { return nil }
        switch (id, re) {
        case (nil, let re?):
            return .note(Note(annotationID: re, author: author, payload: payload, extraKeys: extras))
        case (let id?, nil):
            return .annotation(Annotation(
                id: id,
                author: author,
                intent: resolvedIntent,
                status: resolvedStatus,
                payload: payload,
                extraKeys: extras,
                rawIntent: rawIntent,
                rawStatus: rawStatus
            ))
        default:
            // Neither id nor re, or both: malformed.
            return nil
        }
    }

    /// Marker keys use the grammar's lowercase-letter alphabet.
    static func isKey(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
    }

    /// Values and ids share one constrained alphabet: nonempty `[a-z0-9-]`.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "-")
        }
    }

    /// Reverse of the sanitizer's escapes. Table pipes: GFM strips `\|` inside
    /// tables before we see it; outside tables the raw marker still carries it.
    /// The `-->` zero-width-space split is reversed too, so the user gets back
    /// the exact bytes they typed (review decision — the legacy one-way
    /// behavior silently mutated payloads).
    private static func desanitize(_ payload: String, usesLineEncoding: Bool) -> String {
        let tableSafe = payload
            .replacingOccurrences(of: "--\u{200B}>", with: "-->")
            .replacingOccurrences(of: "\\|", with: "|")
        guard usesLineEncoding else { return tableSafe }

        var result = ""
        var index = tableSafe.startIndex
        while index < tableSafe.endIndex {
            let character = tableSafe[index]
            guard character == "\\" else {
                result.append(character)
                index = tableSafe.index(after: index)
                continue
            }
            let nextIndex = tableSafe.index(after: index)
            guard nextIndex < tableSafe.endIndex else {
                result.append("\\")
                break
            }
            switch tableSafe[nextIndex] {
            case "n": result.append("\n")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(tableSafe[nextIndex])
            }
            index = tableSafe.index(after: nextIndex)
        }
        return result
    }
}

// MARK: - Serialization

extension PlanAnnotationMarker {
    /// The single-line `<!-- AMX … -->` text for this marker. Keys at their
    /// default values are omitted so untouched markers stay short; extra keys
    /// are re-emitted in original order; the payload is sanitized for the
    /// single-line HTML-comment context (see CommentMarkerWriter.sanitizeNote).
    public func serialized() -> String? {
        var keys: [String] = []
        let payload: String
        let extras: [ExtraKey]
        switch self {
        case let .annotation(a):
            keys.append("id=\(a.id)")
            keys.append("by=\(a.author.rawValue)")
            // A preserved unknown value wins over the degraded enum: the parse
            // guard already constrained it to the token alphabet, so re-emitting
            // it verbatim is safe and keeps a future schema's state intact.
            if let rawIntent = a.rawIntent {
                keys.append("intent=\(rawIntent)")
            } else if a.intent != .comment {
                keys.append("intent=\(a.intent.rawValue)")
            }
            if let rawStatus = a.rawStatus {
                keys.append("status=\(rawStatus)")
            } else if a.status != .open {
                keys.append("status=\(a.status.rawValue)")
            }
            payload = a.payload
            extras = a.extraKeys
        case let .note(n):
            keys.append("re=\(n.annotationID)")
            keys.append("by=\(n.author.rawValue)")
            payload = n.payload
            extras = n.extraKeys
        }
        let alreadyLineEncoded = extras.contains { $0.key == "encoding" && $0.value == "lines" }
        // Scalar-level check: "\r\n" is a single grapheme, so Character-level
        // `contains` sees neither "\n" nor "\r" in it — the payload would skip
        // line encoding and sanitizeNote would collapse the break to a space.
        // Same grapheme trap as parseColumnAlignments.
        let needsLineEncoding = alreadyLineEncoded
            || payload.unicodeScalars.contains("\n")
            || payload.unicodeScalars.contains("\r")
        keys.append(contentsOf: extras.map { "\($0.key)=\($0.value)" })
        if needsLineEncoding, !alreadyLineEncoded {
            keys.append("encoding=lines")
        }

        let head = "<!-- AMX " + keys.joined(separator: " ")
        let storagePayload = needsLineEncoding ? Self.encodeLines(payload) : payload
        let safePayload = CommentMarkerWriter.sanitizeNote(storagePayload)
        // The cap applies to the STORED payload: escaping expands input, and
        // parse() rejects stored payloads over the cap — validating the
        // unencoded payload would let a write succeed that turns into inert
        // HTML on the next reload.
        guard safePayload.utf8.count <= Self.maxPayloadBytes else { return nil }
        return safePayload.isEmpty ? head + " -->" : head + ": " + safePayload + " -->"
    }

    private static func encodeLines(_ payload: String) -> String {
        payload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}

// MARK: - ID generation

public extension PlanAnnotationMarker {
    /// Generate a fresh annotation id: 4 lowercase base36 characters with at
    /// least one letter. The letter requirement keeps generated ids disjoint
    /// from legacy integer ids, so migration never collides (contract rule).
    /// Re-rolls on collision with `existing` or an all-digit draw.
    static func generateID(
        existing: Set<String>,
        using rng: inout some RandomNumberGenerator
    ) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let candidate = String((0 ..< 4).map { _ in alphabet.randomElement(using: &rng)! })
            let hasLetter = candidate.utf8.contains { $0 >= UInt8(ascii: "a") }
            if hasLetter, !existing.contains(candidate) {
                return candidate
            }
        }
    }

    static func generateID(existing: Set<String>) -> String {
        var rng = SystemRandomNumberGenerator()
        return generateID(existing: existing, using: &rng)
    }
}
