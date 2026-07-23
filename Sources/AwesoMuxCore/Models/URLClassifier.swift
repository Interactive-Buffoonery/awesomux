import Foundation
import UnicodeHygiene

/// Routes OSC 8 hyperlink click-throughs to either a direct open or a
/// block-confirm modal, based on the URL's threat profile.
///
/// v1 posture (INT-16), refined per TR39 in INT-454:
/// - Block a host when a DNS label either mixes scripts that could be
///   confused for one another (the classic Latin/Cyrillic/Greek homograph
///   triad — see `UnicodeHygiene.hasSuspiciousScriptMixing`) OR is a
///   whole-script confusable: entirely one non-Latin script whose every
///   letter is a known Latin lookalike (`аррӏе.com` ≈ "apple.com", pure
///   Cyrillic — see `hostHasWholeScriptConfusableLabel`). A legitimate
///   single-script host whose letters aren't all Latin lookalikes
///   (`яндекс.рф`, `москва.com`, `日本語.jp`) opens direct even though it
///   isn't ASCII.
/// - Block any `mailto:` with attacker-controllable prefill parameters
///   (`to`, `body`, `cc`, `bcc`, `subject`).
/// - Block any HTTP(S) URL with embedded `userinfo` — the `user@host`
///   trick disguises the real host (the oldest phishing trick on the
///   web, predates IDN homographs).
/// - Block any HTTP(S) URL whose host is missing (malformed input —
///   `https:/example.com`, `https:///path`).
/// - Block any URL whose path contains bidi-override, zero-width, or
///   other invisible-control codepoints (RTL-override file-extension
///   spoofing, etc.).
/// - Block any scheme outside the http/https/mailto allowlist.
///
/// Documented v1 gaps (not threats this version addresses):
/// - **IP-literal hosts** (`http://192.0.2.1/`, `http://[::1]/`,
///   `http://localhost/`) open direct. Useful for dev workflows;
///   "click this raw IP from a phishing email" is a known unprotected
///   surface. Revisit if friction-vs-protection tradeoff shifts.
/// - **TR39 "Highly Restrictive" exceptions** (e.g. Latin+Han+Hiragana+
///   Katakana, the legitimate-Japanese-domain combination) aren't
///   hand-implemented — `UnicodeHygiene.hasSuspiciousScriptMixing` only
///   recognizes Latin/Cyrillic/Greek, so non-Latin scripts outside that
///   triad never register as "mixed" in the first place. Revisit if a
///   real confusable combination outside the triad shows up.
/// - **Whole-script confusables outside the curated Cyrillic table**
///   (#143). `hostHasWholeScriptConfusableLabel` flags a pure-non-Latin
///   label only when every letter is in a small hand-audited Cyrillic→Latin
///   lookalike set, chosen to keep false positives near zero on legitimate
///   single-script domains. The accepted ceiling: a Latin string needing a
///   letter with no Cyrillic lowercase twin (g, m, n, k, …) can't be spelled
///   from the table and isn't caught; Greek and other scripts aren't
///   covered; and one non-lookalike scalar appended to an otherwise-
///   confusable label opens it direct (which also degrades the visual
///   spoof). Widen the table or add scripts when a real miss surfaces.
/// - **Peek-popover** for safe URLs — preview-before-click is INT-453.
public enum URLClassifier {
    public enum Decision: Equatable, Sendable {
        case openDirect
        case blockConfirm(reason: BlockReason, displayHost: String?, punycodeHost: String?)
    }

    public enum BlockReason: String, Equatable, Sendable {
        /// Host has a DNS label that mixes scripts confusable for one
        /// another (TR39 homograph risk — `pаypal.com` with a Cyrillic `а`)
        /// or is a whole-script confusable (`аррӏе.com`, entirely Cyrillic
        /// yet reads as "apple"), or a punycode label Foundation failed to
        /// decode to Unicode
        /// (can't verify content, so treated as suspicious). The user
        /// should see what punycode actually resolves to before clicking
        /// through.
        case nonAsciiHost
        /// HTTP(S) URL with embedded `userinfo` (`user[:pass]@host`).
        /// Almost always a phishing attempt — userinfo is largely
        /// vestigial in modern browsers and overwhelmingly used to
        /// disguise the real host.
        case embeddedUserInfo
        /// HTTP(S) URL whose host accessor returns nil. Indicates a
        /// malformed input that may have parsed unexpectedly.
        case missingHost
        /// URL path contains invisible/bidi-override/control codepoints
        /// that can spoof the file extension or section being opened.
        /// Same character set `WorkspaceConfig.normalizedDefaultGroup`
        /// strips from workspace names.
        case pathHasUnsafeCodepoints
        /// `mailto:` URL with one or more recipient/prefill query
        /// parameters: `to`, `body`, `cc`, `bcc`, `subject`. Per RFC 6068
        /// these are all attacker-controllable.
        case mailtoWithParameters
        /// Scheme isn't in the allowlist. `OpenURLAction.url` should
        /// drop these earlier — defense-in-depth for direct callers.
        case disallowedScheme
    }

    /// The same allowlist `OpenURLAction.allowedSchemes` enforces.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// `mailto:` query parameters whose presence (with non-empty value)
    /// indicates attacker-controllable prefill. Per RFC 6068, `to` is a
    /// valid recipient field via query string in addition to the path
    /// position — leaving it off the list would let an attacker spoof
    /// the recipient without ever populating the path. `in-reply-to`
    /// and `references` are intentionally excluded — they're headers
    /// a hostile remote can't usefully prefill against a phishing
    /// target.
    private static let mailtoPhishingParameters: Set<String> = [
        "to", "body", "cc", "bcc", "subject",
    ]

    /// Codepoints that are invisible / direction-flipping / zero-width
    /// when embedded in a URL path. Matches the character set
    /// `WorkspaceConfig.normalizedDefaultGroup` strips from workspace
    /// names. RTL override (`U+202E`) is the canonical "rename
    /// `evil.exe` to `gnp.txt`" attack carrier.
    private static let unsafePathCodepoints: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = []
        // Bidi formatting controls.
        for value: UInt32 in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E] {
            if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
        }
        // Bidi isolates.
        for value: UInt32 in [0x2066, 0x2067, 0x2068, 0x2069] {
            if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
        }
        // Implicit-direction marks (LRM, RLM, ALM).
        for value: UInt32 in [0x200E, 0x200F, 0x061C] {
            if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
        }
        // Line / paragraph separators.
        for value: UInt32 in [0x2028, 0x2029] {
            if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
        }
        // Zero-width / word-joiner / BOM.
        for value: UInt32 in [0x200B, 0xFEFF, 0x2060] {
            if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
        }
        return set
    }()

    public static func classify(_ url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme)
        else {
            return .blockConfirm(
                reason: .disallowedScheme,
                displayHost: nil,
                punycodeHost: nil
            )
        }

        if scheme == "mailto" {
            return classifyMailto(url)
        }

        return classifyHTTP(url)
    }

    private static func classifyMailto(_ url: URL) -> Decision {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let hasPhishingParam = queryItems.contains { item in
            mailtoPhishingParameters.contains(item.name.lowercased())
                && !(item.value?.isEmpty ?? true)
        }
        if hasPhishingParam {
            return .blockConfirm(
                reason: .mailtoWithParameters,
                displayHost: nil,
                punycodeHost: nil
            )
        }
        return .openDirect
    }

    private static func classifyHTTP(_ url: URL) -> Decision {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Userinfo phishing (`https://github.com@evil.example/`,
        // `https://:secret@evil.example/`). Catch before the host check
        // because the *visible* spoof lives in the userinfo, but the
        // *resolved* host is what NSWorkspace opens. Check BOTH user and
        // password — Foundation parses `https://:foo@host/` with empty
        // user and non-empty password, and a `:foo@` prefix is just as
        // capable of disguising the real host as a `foo@` prefix.
        let hasUser = (components?.user?.isEmpty == false)
        let hasPassword = (components?.password?.isEmpty == false)
        if hasUser || hasPassword {
            return .blockConfirm(
                reason: .embeddedUserInfo,
                displayHost: components?.host,
                punycodeHost: url.host(percentEncoded: false)
            )
        }

        // Two host accessors return different forms — pick deliberately:
        //   URLComponents.host           → Unicode (decodes xn-- AND keeps raw Cyrillic intact)
        //   url.host(percentEncoded: false) → punycode (preserves xn--)
        // We display the Unicode form to the user, surface punycode as the
        // "actually-resolved" form to expose homograph attacks.
        //
        // Normalize empty strings to nil up-front: `https:///path` parses
        // with `URLComponents.host == ""` (not nil) on macOS, and an
        // empty host is semantically the same as no host for our purposes.
        let displayHost = nonEmpty(components?.host)
        let punycodeHost = nonEmpty(url.host(percentEncoded: false))

        // No host on an http(s) URL = malformed input. Treat as
        // suspicious — `https:/example.com` (single slash) and
        // `https:///path` (three slashes) both parse to a URL with
        // scheme set but no resolvable host.
        if displayHost == nil && punycodeHost == nil {
            return .blockConfirm(
                reason: .missingHost,
                displayHost: nil,
                punycodeHost: nil
            )
        }

        // Foundation percent-decodes the host before exposing it via
        // `URLComponents.host`, so `https://exa%0Ample.com/` decodes to
        // a host containing a literal newline. It similarly decodes
        // malformed reserved delimiters like `%40` and `%2F` into the host.
        // These are pure ASCII, no `xn--` label, but malformed/phishing-
        // shaped. Treat as suspicious.
        let hostHasUnsafeScalar =
            (displayHost.map(hostContainsUnsafeAuthorityScalar) ?? false)
            || (punycodeHost.map(hostContainsUnsafeAuthorityScalar) ?? false)

        // An IDN host must decode fully to Unicode before we trust script
        // analysis on it. `punycodeHost` carries the `xn--` form for ANY
        // IDN host regardless of decode success, so it's the right signal
        // for "this is an IDN host at all." If that's true but `displayHost`
        // is nil (Foundation failed to decode invalid/malformed punycode —
        // `URLComponents.host` returns nil, not the raw `xn--` text, e.g.
        // `xn--a.com`) or still literally shows `xn--` (partial decode
        // failure), we can't inspect the real content. Block rather than
        // guess — this also covers a multi-label host where just one label
        // fails to decode (`good.xn--a.com`), which blanks `displayHost`
        // for the WHOLE host, not just that label.
        let hostFailedPunycodeDecode: Bool = {
            guard let punycodeHost, hostContainsPunycodeLabel(punycodeHost) else { return false }
            guard let displayHost else { return true }
            return hostContainsPunycodeLabel(displayHost)
        }()

        // TR39 mixed-script detection (INT-454): block a label only when it
        // mixes scripts that could be confused for one another — the same
        // Latin/Cyrillic/Greek homograph policy `UnicodeHygiene` already
        // enforces for display strings elsewhere in the app. A label that's
        // entirely one script — even a non-Latin one like "яндекс" or
        // "日本語" — reads clean. Runs per DNS label, not the whole host, so
        // "日本語.jp" (a pure-Han label plus a pure-ASCII TLD label) stays
        // open-direct.
        //
        // `UnicodeHygiene.hasSuspiciousScriptMixing`'s contract asks for raw
        // pre-NFKC input elsewhere in the app (workspace titles), but
        // `displayHost` here has already been through Foundation's IDNA
        // processing, which folds some compatibility characters (`µ` →
        // Greek `μ`). That's fine for this call site specifically: a folded
        // host that now "mixes" is either genuinely non-ASCII (already
        // blocked pre-INT-454 too — no new false positive) or a punycode
        // round-trip Foundation already normalized before we ever see it.
        let hostIsMixedScript = displayHost.map(hostHasMixedScriptLabel) ?? false

        // TR39 whole-script confusables (#143): mixed-script leaves a label
        // that's *entirely* one non-Latin script untouched, so a pure-Cyrillic
        // label that spells a Latin word in homoglyphs (`аррӏе` ≈ "apple")
        // reads clean above. Catch it here and route to the same soft confirm.
        let hostIsWholeScriptConfusable =
            displayHost.map(hostHasWholeScriptConfusableLabel) ?? false

        if hostHasUnsafeScalar || hostFailedPunycodeDecode || hostIsMixedScript
            || hostIsWholeScriptConfusable
        {
            return .blockConfirm(
                reason: .nonAsciiHost,
                displayHost: displayHost ?? punycodeHost,
                punycodeHost: punycodeHost ?? displayHost
            )
        }

        // Path-content threat: RTL override, zero-width, etc. The host
        // is ASCII and clean, but the path could still spoof what's
        // about to open. Check AFTER the host gates so a non-ASCII host
        // surfaces its (more recognizable) reason first.
        if pathContainsUnsafeCodepoint(url) {
            return .blockConfirm(
                reason: .pathHasUnsafeCodepoints,
                displayHost: displayHost,
                punycodeHost: punycodeHost
            )
        }

        return .openDirect
    }

    /// Returns the string unless it's nil or empty, in which case nil.
    /// Used to normalize Foundation's "host accessor sometimes returns
    /// empty string instead of nil" behavior for malformed URLs.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Control characters and other codepoints that have no business
    /// appearing inside any percent-decoded URL component we display or
    /// classify.
    /// `< 0x20` covers ASCII C0 controls (NUL, LF, CR, tab, etc.) —
    /// Foundation percent-decodes `%0A` etc. so these can appear in
    /// `URLComponents.host`. `0x7F` is DEL. C1 controls (`0x80–0x9F`)
    /// are non-ASCII so they're caught by the wider non-ASCII gate;
    /// listing them here is belt-and-suspenders.
    private static func isUnsafeDecodedURLScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
            || unsafePathCodepoints.contains(scalar)
    }

    /// Detects scalar-level host hazards after Foundation percent-decodes
    /// the authority. In addition to generic invisible/control codepoints,
    /// decoded `@`, `/`, `?`, `#`, `[`, and `]` make the host malformed or
    /// phishing-shaped. `:` is intentionally not treated as unsafe because
    /// `URLComponents.host` exposes IPv6 literals with colons.
    private static func hostContainsUnsafeAuthorityScalar(_ host: String) -> Bool {
        let isBracketedIPv6Literal = host.hasPrefix("[") && host.hasSuffix("]") && host.contains(":")
        return host.unicodeScalars.contains { scalar in
            if isUnsafeDecodedURLScalar(scalar) {
                return true
            }
            let character = Character(scalar)
            if isBracketedIPv6Literal && (character == "[" || character == "]") {
                return false
            }
            return ["/", "?", "#", "[", "]", "@"].contains(character)
        }
    }

    /// Detects an `xn--` label anywhere in a hostname (any DNS label
    /// may be IDN-encoded independently of its siblings).
    private static func hostContainsPunycodeLabel(_ host: String) -> Bool {
        host.lowercased().split(separator: ".").contains { label in
            label.hasPrefix("xn--")
        }
    }

    /// TR39 mixed-script is a per-label property, not a whole-host one —
    /// evaluating the concatenated host would flag legitimate hosts like
    /// `日本語.jp` (pure-Han label + pure-ASCII TLD label) as mixed.
    private static func hostHasMixedScriptLabel(_ host: String) -> Bool {
        host.split(separator: ".").contains { label in
            UnicodeHygiene.hasSuspiciousScriptMixing(String(label))
        }
    }

    /// Cyrillic letters that are convincing *lowercase* Latin homoglyphs —
    /// the whole-script-confusable alphabet (#143). Values are lowercase and
    /// `labelIsWholeScriptConfusable` lowercases its input first, so uppercase
    /// Cyrillic is covered for free (Swift's `String.lowercased()` is
    /// Unicode-aware: `А` → `а`) without a second table.
    ///
    /// INVARIANT — Cyrillic ONLY. This single-script table is exactly what
    /// makes "the label is 100% one non-Latin script" true by construction: a
    /// label whose non-ASCII scalars are all in this set can only be Cyrillic.
    /// Adding another script's letters here silently breaks that guarantee —
    /// re-audit `labelIsWholeScriptConfusable` before you do. (The sibling
    /// `UnicodeHygiene.scriptFamily` table was mis-edited three times by
    /// treating letter *names* as script; verify any addition against
    /// Unicode's real Script property, not visual resemblance.)
    ///
    /// Deliberately small and conservative: letters with no clean lowercase
    /// Latin twin (`м`, `н`, `к`, `я`, …) are omitted, so `москва`/`яндекс`
    /// stay open and a spoof needing an absent letter (e.g. "google" — no
    /// Cyrillic lowercase "g") reads clean. That false-negative ceiling is the
    /// price of near-zero false positives, and it's a soft confirm, not a
    /// hard block.
    private static let cyrillicLatinLookalikes: Set<Unicode.Scalar> = [
        "\u{0430}",  // а → a
        "\u{044C}",  // ь → b  (Cyrillic soft sign — closes the еьау≈"ebay" vector)
        "\u{0441}",  // с → c
        "\u{0501}",  // ԁ → d  (Cyrillic komi de)
        "\u{0435}",  // е → e
        "\u{04BB}",  // һ → h  (Cyrillic shha)
        "\u{0456}",  // і → i  (Cyrillic byelorussian-ukrainian i)
        "\u{0458}",  // ј → j  (Cyrillic je)
        "\u{04CF}",  // ӏ → l  (Cyrillic palochka)
        "\u{043E}",  // о → o
        "\u{0440}",  // р → p
        "\u{051B}",  // ԛ → q  (Cyrillic qa)
        "\u{0455}",  // ѕ → s  (Cyrillic dze)
        "\u{0475}",  // ѵ → v  (Cyrillic izhitsa — closes the ѵіѕа≈"visa" vector)
        "\u{051D}",  // ԝ → w  (Cyrillic we)
        "\u{0445}",  // х → x
        "\u{0443}",  // у → y
    ]

    /// TR39 whole-script confusable detection (#143), per DNS label — the same
    /// per-label scoping as `hostHasMixedScriptLabel`, so a dangerous label
    /// (`аррӏе`) is flagged even when a safe sibling label (`.com`, or a
    /// non-confusable Cyrillic label) sits beside it.
    private static func hostHasWholeScriptConfusableLabel(_ host: String) -> Bool {
        host.split(separator: ".").contains { label in
            labelIsWholeScriptConfusable(String(label))
        }
    }

    /// `true` when `label` is entirely one non-Latin script (Cyrillic, by the
    /// table's construction) AND every letter is a known Latin lookalike —
    /// i.e. it spells a plausible Latin string in homoglyphs (`аррӏе` ≈
    /// "apple"). A single non-lookalike non-ASCII scalar (`я`, `н`, a
    /// combining mark, …) means it's a real word in that script, not a spoof,
    /// so we bail and leave it open.
    ///
    /// ASCII scalars (digits, hyphens) are neutral and skipped — they can't be
    /// the non-Latin confusable risk. An ASCII *letter* beside a lookalike is
    /// mixed-script, already flagged by `hostHasMixedScriptLabel` with the
    /// identical `.nonAsciiHost` decision; this predicate also returning true
    /// there is harmless redundancy, never a new false positive.
    private static func labelIsWholeScriptConfusable(_ label: String) -> Bool {
        var sawLookalike = false
        for scalar in label.lowercased().unicodeScalars {
            if scalar.isASCII { continue }
            guard cyrillicLatinLookalikes.contains(scalar) else { return false }
            sawLookalike = true
        }
        return sawLookalike
    }

    /// Detects invisible / direction-flipping / zero-width codepoints
    /// AND ASCII control characters anywhere in the URL path, query,
    /// or fragment. Operates on the Unicode-decoded form so percent-
    /// encoded `%0A` (LF) or `%E2%80%AE` (RTL override) are caught the
    /// same as raw codepoints. Without this, `%0A` decoded to a literal
    /// newline in the path and passed all the gates.
    private static func pathContainsUnsafeCodepoint(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        let query = components?.query ?? ""
        let fragment = components?.fragment ?? ""
        let combined = path.unicodeScalars + query.unicodeScalars + fragment.unicodeScalars
        return combined.contains(where: isUnsafeDecodedURLScalar)
    }
}
