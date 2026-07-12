import AwesoMuxCore
import Foundation

struct RemoteMarkdownReference: Equatable, Sendable {
    let sshTarget: String
    let remotePath: String
    let origin: String

    static func make(payload: String, pane: TerminalPane) -> RemoteMarkdownReference? {
        guard let host = pane.remoteHost.flatMap(trimmedNonEmpty),
              let remotePath = remotePath(from: payload) else {
            return nil
        }
        guard !remotePath.hasPrefix("~") || remotePath.hasPrefix("~/") else {
            return nil
        }
        let titleInfo = RemoteTitleInfo.parse(pane.liveTerminalTitle ?? pane.title)
        let titleMatchesHost = titleInfo?.host.caseInsensitiveCompare(host) == .orderedSame
        let user = titleMatchesHost ? titleInfo?.user : nil
        let directory = titleMatchesHost ? titleInfo?.directory ?? pane.remoteWorkingDirectory : pane.remoteWorkingDirectory
        let resolvedPath = resolve(remotePath, relativeTo: directory)
        guard isSupportedRemotePath(resolvedPath) else {
            return nil
        }
        let target = pane.remoteSSHTarget.flatMap(trimmedNonEmpty)
            ?? user.map { "\($0)@\(host)" }
            ?? host
        // Never let an SSH destination begin with `-`. Without a guaranteed
        // OpenSSH `--` end-of-options, a `-`-leading target — reachable from a
        // spoofed title whose username charset permits a leading dash — would be
        // parsed by ssh as an option rather than a host. Fail closed.
        guard !target.hasPrefix("-") else {
            return nil
        }
        return RemoteMarkdownReference(
            sshTarget: target,
            remotePath: resolvedPath,
            origin: "\(target):\(resolvedPath)"
        )
    }

    static func isPotentialPayload(_ payload: String) -> Bool {
        guard let path = remotePath(from: payload),
              !path.isEmpty,
              !path.contains("\0"),
              !path.hasPrefix("~") || path.hasPrefix("~/"),
              !MarkdownLinkIntercept.containsUnsafePathScalars(path) else {
            return false
        }
        return DocumentURLValidator.allowedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func remotePath(from payload: String) -> String? {
        guard !payload.isEmpty,
              let parsed = URL(string: payload) else {
            return nil
        }
        if parsed.scheme == nil {
            // libghostty's bare-path regex hands remote panes the same raw,
            // schemeless match as local panes — including trailing sentence
            // punctuation (see MarkdownLinkIntercept.strippingTrailingSentencePunctuation).
            // Without this, a remote path mentioned at the end of a sentence
            // fails isPotentialPayload's extension check below and falls
            // through to local resolution, which can silently open a
            // same-spelled local file instead of fetching the remote one.
            return MarkdownLinkIntercept.strippingTrailingSentencePunctuation(payload)
        }
        guard parsed.scheme?.lowercased() == "file",
              parsed.query == nil else {
            return nil
        }
        return parsed.path
    }

    private static func resolve(_ path: String, relativeTo directory: String?) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        if path.hasPrefix("~/") {
            return path
        }
        guard let directory, directory.hasPrefix("/") || directory.hasPrefix("~/") else {
            return path
        }
        if directory.hasPrefix("~/") {
            return (directory as NSString).appendingPathComponent(path)
        }
        return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private static func isSupportedRemotePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.hasPrefix("~") || path.hasPrefix("~/"),
              !MarkdownLinkIntercept.containsUnsafePathScalars(path),
              DocumentURLValidator.allowedExtensions.contains((path as NSString).pathExtension.lowercased())
        else {
            return false
        }
        return path.hasPrefix("/") || path.hasPrefix("~/")
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RemoteMarkdownSnapshotFetcher {
    var cacheDirectoryURL: URL = SessionPersistence.supportDirectoryURL
        .appending(path: "remote-markdown", directoryHint: .isDirectory)
    var runner = BoundedCommandRunner(
        executableCandidates: ["/usr/bin/ssh"],
        timeout: .seconds(8),
        maxOutputBytes: DocumentURLValidator.maxFileSizeBytes + 1
    )
    var fileManager: FileManager = .default

    func fetch(_ reference: RemoteMarkdownReference) async -> (fileURL: URL, origin: String)? {
        let output = await fetchOutput(for: reference)
        let content: Data
        if let output, output.count <= DocumentURLValidator.maxFileSizeBytes {
            content = output
        } else {
            content = Data(failureMarkdown(for: reference).utf8)
        }
        return write(content, for: reference)
    }

    func pruneUnreferencedSnapshots(keeping referencedFileURLs: Set<URL>) {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: cacheDirectoryURL.path)) == nil else {
            return
        }
        guard ((try? cacheDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true else {
            return
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let referencedPaths = Set(referencedFileURLs.map { $0.standardizedFileURL.path })
        for entry in entries where !referencedPaths.contains(entry.standardizedFileURL.path) {
            guard ((try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func fetchOutput(for reference: RemoteMarkdownReference) async -> Data? {
        await runner.run(
            arguments: sshArguments(target: reference.sshTarget, path: reference.remotePath),
            inDirectory: FileManager.default.currentDirectoryPath
        )
    }

    private func sshArguments(target: String, path: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "NumberOfPasswordPrompts=0",
            target,
            remoteReadCommand(path: path)
        ]
    }

    private func remoteReadCommand(path: String) -> String {
        let quotedPath = Self.shellSingleQuoted(path)
        return "p=\(quotedPath); case \"$p\" in \"~/\"*) p=\"$HOME/${p#~/}\";; esac; [ -f \"$p\" ] || exit 1; size=$(wc -c < \"$p\") || exit 1; [ \"$size\" -le \(DocumentURLValidator.maxFileSizeBytes) ] || exit 2; cat -- \"$p\""
    }

    private func write(_ content: Data, for reference: RemoteMarkdownReference) -> (fileURL: URL, origin: String)? {
        do {
            try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            let fileURL = cacheDirectoryURL.appending(path: cacheFileName(for: reference))
            try content.write(to: fileURL, options: .atomic)
            return (fileURL: fileURL, origin: reference.origin)
        } catch {
            return nil
        }
    }

    private func cacheFileName(for reference: RemoteMarkdownReference) -> String {
        let ext = (reference.remotePath as NSString).pathExtension.lowercased()
        return "\(Self.stableHash(reference.origin)).\(ext)"
    }

    private func failureMarkdown(for reference: RemoteMarkdownReference) -> String {
        """
        # Couldn't fetch remote Markdown

        awesoMux could not read `\(Self.markdownInlineCode(reference.origin))` using SSH.

        Check that the host is reachable and your SSH config can connect without an interactive password prompt.
        """
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // Strip backticks rather than backslash-escaping them: a backslash does NOT
    // escape a delimiter inside a CommonMark code span, so a backtick in `origin`
    // could otherwise close the span and inject Markdown into the app-generated
    // failure page. Origins are single-line (control scalars are rejected
    // upstream), so removal keeps them readable while sealing the span.
    static func markdownInlineCode(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

private struct RemoteTitleInfo: Equatable {
    let user: String
    let host: String
    let directory: String?

    static func parse(_ title: String) -> RemoteTitleInfo? {
        var text = title[...]
        while text.first == " " || text.first == "\t" {
            text = text.dropFirst()
        }
        guard let atIndex = text.firstIndex(of: "@") else {
            return nil
        }
        let user = text[..<atIndex]
        guard !user.isEmpty, user.allSatisfy(isUsernameCharacter) else {
            return nil
        }
        let afterAt = text[text.index(after: atIndex)...]
        let host: Substring
        if afterAt.first == "[" {
            guard let close = afterAt.firstIndex(of: "]") else {
                return nil
            }
            host = afterAt[afterAt.startIndex...close]
        } else {
            host = afterAt.prefix { character in
                guard let scalar = character.unicodeScalars.first,
                      character.unicodeScalars.count == 1,
                      scalar.isASCII else {
                    return false
                }
                return character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_"
            }
        }
        guard !host.isEmpty else {
            return nil
        }
        let trailing = afterAt[host.endIndex...]
        guard isPromptShaped(trailing) else {
            return nil
        }
        return RemoteTitleInfo(
            user: String(user),
            host: String(host),
            directory: directory(from: trailing)
        )
    }

    private static func directory(from trailing: Substring) -> String? {
        var rest = trailing
        if rest.first == ":" {
            rest = rest.dropFirst()
        }
        while rest.first == " " || rest.first == "\t" {
            rest = rest.dropFirst()
        }
        guard rest.first == "/" || rest.first == "~" else {
            return nil
        }
        return String(rest.prefix { $0 != " " && $0 != "\t" })
    }

    private static func isPromptShaped(_ trailing: Substring) -> Bool {
        if trailing.isEmpty { return true }

        var rest = trailing
        if rest.first == ":" {
            rest = rest.dropFirst()
            let digits = rest.prefix(while: \.isNumber)
            rest = rest[digits.endIndex...]
        }

        if rest.isEmpty { return true }
        while rest.first == " " || rest.first == "\t" {
            rest = rest.dropFirst()
        }
        if rest.isEmpty { return true }
        return rest.first == "/" || rest.first == "~"
    }

    private static func isUsernameCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        return character.isLetter || character.isNumber
            || character == "." || character == "_" || character == "-" || character == "+"
    }
}
