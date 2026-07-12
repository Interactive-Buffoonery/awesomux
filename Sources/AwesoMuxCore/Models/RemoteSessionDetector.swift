import Foundation

/// What a terminal title tells us about whether a pane is in a remote session.
///
/// awesoMux only learns the cwd from Ghostty's OSC 7 pwd action, and Ghostty
/// *drops* OSC 7 from a non-local host (the SSH case) as anti-spoofing — so over
/// SSH the pwd silently goes stale and the local-only Path Bar affordances would
/// act on the wrong machine. Ghostty does NOT host-validate the title (OSC 0/2),
/// so a remote shell's `user@host` prompt title still reaches us; that title is
/// the only in-repo signal a pane went remote. (INT-508 SSH addendum. The robust
/// signals — Ghostty's OSC 3008 context signal, the pty child pid — aren't in
/// libghostty's C API yet and are deferred.)
public enum RemoteSessionSignal: Equatable, Sendable {
    /// The title names a foreign host → the pane is remote.
    case remote(host: String)
    /// The title names our own host (or loopback) → definitively local.
    case local
    /// No usable `user@host` token → leave any prior remote state untouched.
    /// This is what makes detection *sticky*: a remote shell that rewrites its
    /// title to the running command between prompts returns `.indeterminate`, so
    /// the pane stays remote until a local OSC 7 pwd event clears it.
    case indeterminate
}

public enum RemoteSessionDetector {
    /// Longest title prefix worth scanning; a `user@host` prompt is short, and a
    /// pathological multi-kilobyte title shouldn't drive the parser.
    private static let scanLimit = 512

    /// Classifies a terminal title against the set of this machine's hostnames.
    ///
    /// Only a *leading* `user@host` token counts, the host must be a syntactically
    /// valid hostname/IP, and the text after it must be "prompt-shaped" (empty, a
    /// `:`, or whitespace then a path) — so a title like `user@example.com — Mail` (an
    /// address embedded in prose) is rejected rather than mistaken for an SSH host.
    /// Fails closed: with no local names to compare against, a foreign-looking host
    /// yields `.indeterminate`, never `.remote` — we never hide local affordances on
    /// a guess about our own identity.
    public static func detect(title: String, localNames: Set<String>) -> RemoteSessionSignal {
        var scanner = Substring(title.prefix(scanLimit))

        // Leading whitespace, then a non-empty user with no whitespace, then '@'.
        while let first = scanner.first, first == " " || first == "\t" {
            scanner = scanner.dropFirst()
        }
        guard let atIndex = scanner.firstIndex(of: "@") else {
            return .indeterminate
        }
        let user = scanner[scanner.startIndex..<atIndex]
        guard !user.isEmpty, user.allSatisfy(isUsernameCharacter) else {
            // The user must look like a shell username — this rejects whitespace
            // (incl. newlines in a multiline title) and URL-ish prefixes like the
            // `ssh://user` in a `ssh://user@host:22` URL that happens to be the title.
            return .indeterminate
        }

        // Host: a bracketed IPv6 literal (`[..]`), else the leading run of
        // hostname/IPv4 characters. A bare `:` is NOT a host character here — it
        // delimits the prompt path (`user@host: ~/x`) or a port — so it stops the
        // run and isn't greedily eaten. Restricting the capture to ASCII host
        // characters means the result can never carry control or bidi bytes, so it
        // is safe to display without further sanitization.
        let afterAt = scanner[scanner.index(after: atIndex)...]
        let host: Substring
        if afterAt.first == "[" {
            guard let close = afterAt.firstIndex(of: "]") else {
                return .indeterminate
            }
            host = afterAt[afterAt.startIndex...close]
        } else {
            host = afterAt.prefix { character in
                guard let scalar = character.unicodeScalars.first,
                      character.unicodeScalars.count == 1, scalar.isASCII else {
                    return false
                }
                return character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_"
            }
        }
        guard !host.isEmpty else {
            return .indeterminate
        }

        let trailing = afterAt[host.endIndex...]
        guard isPromptShaped(trailing) else {
            return .indeterminate
        }

        let hostString = String(host)
        guard isValidHostSyntax(hostString) else {
            return .indeterminate
        }

        let lowerHost = hostString.lowercased()
        if isLoopback(lowerHost) {
            return .local
        }

        // Match the candidate's FULL name against the local set (which already
        // holds both the short and FQDN forms of every local name). Crucially, do
        // NOT reduce an FQDN candidate to its short label before matching: a remote
        // `macbook.corp` shares the short label `macbook` with a local
        // `macbook.local`, and treating it as local would be a false *clear* — the
        // dangerous direction (local chips on a remote). A bare-label candidate
        // matches the local short form directly, so no reduction is needed.
        if localNames.contains(lowerHost) {
            return .local
        }

        // Fail closed: without a baseline for our own name, don't claim remote.
        guard !localNames.isEmpty else {
            return .indeterminate
        }

        return .remote(host: hostString)
    }

    public static func promptDirectory(title: String) -> String? {
        var scanner = Substring(title.prefix(scanLimit))
        while let first = scanner.first, first == " " || first == "\t" {
            scanner = scanner.dropFirst()
        }
        guard let atIndex = scanner.firstIndex(of: "@") else {
            return nil
        }

        let afterAt = scanner[scanner.index(after: atIndex)...]
        let hostEnd: Substring.Index
        if afterAt.first == "[" {
            guard let close = afterAt.firstIndex(of: "]") else {
                return nil
            }
            hostEnd = afterAt.index(after: close)
        } else {
            let host = afterAt.prefix { character in
                guard let scalar = character.unicodeScalars.first,
                      character.unicodeScalars.count == 1,
                      scalar.isASCII else {
                    return false
                }
                return character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_"
            }
            hostEnd = host.endIndex
        }

        var rest = afterAt[hostEnd...]
        if rest.first == ":" {
            rest = rest.dropFirst()
            let digits = rest.prefix(while: \.isNumber)
            rest = rest[digits.endIndex...]
        }
        while rest.first == " " || rest.first == "\t" {
            rest = rest.dropFirst()
        }
        guard rest.first == "/" || rest.first == "~" else {
            return nil
        }
        return String(rest.prefix { $0 != " " && $0 != "\t" })
    }

    private static func isUsernameCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first, scalar.isASCII else {
            return false
        }
        return character.isLetter || character.isNumber
            || character == "." || character == "_" || character == "-" || character == "+"
    }

    /// The text after the host must look like a shell prompt, not prose. Allowed:
    /// nothing; an optional `:` (path separator or port) followed by a numeric
    /// port, a path (`/`/`~`), whitespace-then-path, or just whitespace. This
    /// accepts `user@host`, `user@host:~/dir`, `user@host: ~/dir`, `user@host:22`,
    /// and `user@host /abs`, while rejecting prose like `user@example.com: Inbox`.
    private static func isPromptShaped(_ trailing: Substring) -> Bool {
        if trailing.isEmpty { return true }

        var rest = trailing
        if rest.first == ":" {
            rest = rest.dropFirst()
            // An optional numeric port directly after the colon.
            let digits = rest.prefix(while: \.isNumber)
            rest = rest[digits.endIndex...]
        }

        if rest.isEmpty { return true }
        var index = rest.startIndex
        while index < rest.endIndex, rest[index] == " " || rest[index] == "\t" {
            index = rest.index(after: index)
        }
        if index == rest.endIndex {
            return true // only whitespace (and/or a consumed port) remains
        }
        return rest[index] == "/" || rest[index] == "~"
    }

    private static func isLoopback(_ lowerHost: String) -> Bool {
        if lowerHost == "localhost" || lowerHost == "::1" || lowerHost == "[::1]" {
            return true
        }
        // 127.0.0.0/8 — only for an actual IPv4 literal, never a DNS name that
        // merely starts with "127." (e.g. `127.example.com` is a remote host).
        return isIPv4(lowerHost) && lowerHost.hasPrefix("127.")
    }

    private static func isValidHostSyntax(_ host: String) -> Bool {
        // A real host can't exceed the DNS name limit; this also hard-caps what's
        // ever displayed, independent of the scan limit.
        guard host.count <= 253 else { return false }
        if host.hasPrefix("[") {
            // Bracketed IPv6 literal: `[....]` with hex digits and colons inside.
            guard host.hasSuffix("]"), host.count > 2 else { return false }
            let inner = host.dropFirst().dropLast()
            return inner.allSatisfy { $0.isHexDigit || $0 == ":" } && inner.contains(":")
        }
        if host.contains(":") {
            // Bare IPv6 literal.
            return host.allSatisfy { $0.isHexDigit || $0 == ":" } && host.contains(":")
        }
        if isIPv4(host) {
            return true
        }
        return isHostname(host)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.allSatisfy(\.isNumber), let value = Int(octet) else {
                return false
            }
            return value >= 0 && value <= 255
        }
    }

    private static func isHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            // Underscores aren't strict-RFC, but they're common in SSH aliases and
            // internal hostnames (`dev_api`). Accepting them means such remotes ARE
            // detected — the fail-safe direction for this UX (an undetected remote
            // would keep stale local affordances live).
            return label.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }
}

/// Resolves the set of names that identify *this* machine, normalized for the
/// detector's comparison (lowercased; both full and short pre-first-dot forms).
///
/// Hostname-based only: a pane whose title shows this machine's own LAN interface
/// IP (e.g. `user@192.168.1.50`) is not in this set and would read as remote. That's
/// the fail-safe direction (it only hides local affordances, never acts on the
/// wrong machine), so the interface-IP set (getifaddrs) is intentionally omitted
/// for the MVP.
public enum LocalHostnames {
    public static func resolve() -> Set<String> {
        var names: Set<String> = []
        for name in Host.current().names {
            insert(name, into: &names)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            buffer[buffer.count - 1] = 0 // guarantee NUL termination on a 256-byte name
            let hostnameBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            insert(String(decoding: hostnameBytes, as: UTF8.self), into: &names)
        }
        return names
    }

    private static func insert(_ raw: String, into set: inout Set<String>) {
        let lower = raw.lowercased()
        guard !lower.isEmpty else { return }
        set.insert(lower)
        if let dot = lower.firstIndex(of: ".") {
            set.insert(String(lower[..<dot]))
        }
    }
}
