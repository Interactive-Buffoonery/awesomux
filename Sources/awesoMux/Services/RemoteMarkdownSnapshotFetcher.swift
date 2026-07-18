import AwesoMuxConfig
import AwesoMuxCore
import Foundation

struct RemoteMarkdownReference: Equatable, Sendable {
    let identity: ResourceIdentity

    var target: RemoteTarget {
        guard case .remote(let target) = identity.location else {
            preconditionFailure("Remote Markdown references require a remote identity")
        }
        return target
    }

    var sshTarget: String { target.sshDestination }
    var remotePath: String { identity.path.rawValue }
    var origin: String { identity.remoteDisplayOrigin ?? remotePath }

    static func make(payload: String, pane: TerminalPane) -> RemoteMarkdownReference? {
        guard case .ssh(let execution) = pane.executionPlan,
            let remotePath = remotePath(from: payload)
        else {
            return nil
        }
        guard !remotePath.hasPrefix("~") || remotePath.hasPrefix("~/") else {
            return nil
        }
        guard
            let resolvedPath = resolve(
                remotePath,
                relativeTo: pane.remoteWorkingDirectory
            )
        else {
            return nil
        }
        let identity = ResourceIdentity(
            location: .remote(execution.target),
            path: ResourcePath(rawValue: resolvedPath)
        )
        guard identity.isSupportedRemoteMarkdownSnapshot else {
            return nil
        }
        return RemoteMarkdownReference(identity: identity)
    }

    static func isPotentialPayload(_ payload: String) -> Bool {
        guard let path = remotePath(from: payload),
            !path.isEmpty,
            !path.contains("\0"),
            !path.hasPrefix("~") || path.hasPrefix("~/"),
            !MarkdownLinkIntercept.containsUnsafePathScalars(path)
        else {
            return false
        }
        return DocumentURLValidator.allowedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func remotePath(from payload: String) -> String? {
        guard !payload.isEmpty,
            let parsed = URL(string: payload)
        else {
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
            parsed.query == nil
        else {
            return nil
        }
        return parsed.path
    }

    private static func resolve(_ path: String, relativeTo directory: String?) -> String? {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        if path.hasPrefix("~/") {
            return normalizedTildePath(path)
        }
        guard let directory,
            directory.hasPrefix("/") || directory == "~" || directory.hasPrefix("~/")
        else {
            return nil
        }
        if directory == "~" || directory.hasPrefix("~/") {
            return normalizedTildePath(
                (directory as NSString).appendingPathComponent(path)
            )
        }
        return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private static func normalizedTildePath(_ path: String) -> String? {
        guard path.hasPrefix("~/") else { return nil }
        var components: [Substring] = []
        for component in path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return "~/" + components.joined(separator: "/")
    }

}

struct RemoteMarkdownSnapshot: Equatable, Sendable {
    let fileURL: URL
    let identity: ResourceIdentity
}

private actor RemoteMarkdownFetchCoordinator {
    struct Key: Hashable, Sendable {
        let identity: ResourceIdentity
        let cacheDirectoryPath: String
    }

    static let shared = RemoteMarkdownFetchCoordinator()

    private var inFlight: [Key: Task<RemoteMarkdownSnapshot?, Never>] = [:]

    func value(
        for key: Key,
        onCoalesced: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async -> RemoteMarkdownSnapshot?
    ) async -> RemoteMarkdownSnapshot? {
        if let existing = inFlight[key] {
            await onCoalesced?()
            return await existing.value
        }
        let task = Task(operation: operation)
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}

// FileManager is documented as safe to use from multiple threads, but does not
// yet declare Sendable in Foundation. The remaining stored values are Sendable.
struct RemoteMarkdownSnapshotFetcher: @unchecked Sendable {
    var cacheDirectoryURL: URL = SessionPersistence.supportDirectoryURL
        .appending(path: "remote-markdown", directoryHint: .isDirectory)
    var runner = BoundedCommandRunner(
        executableCandidates: ["/usr/bin/ssh"],
        timeout: .seconds(8),
        maxOutputBytes: DocumentURLValidator.maxFileSizeBytes + 1
    )
    var fileManager: FileManager = .default
    var fetchOverride: (@Sendable (RemoteMarkdownReference) async -> Data?)?
    var onCoalescedFetch: (@Sendable () async -> Void)?

    func fetch(_ reference: RemoteMarkdownReference) async -> RemoteMarkdownSnapshot? {
        let key = RemoteMarkdownFetchCoordinator.Key(
            identity: reference.identity,
            cacheDirectoryPath: cacheDirectoryURL.standardizedFileURL.path
        )
        return await RemoteMarkdownFetchCoordinator.shared.value(
            for: key,
            onCoalesced: onCoalescedFetch
        ) {
            await fetchUncoordinated(reference)
        }
    }

    private func fetchUncoordinated(
        _ reference: RemoteMarkdownReference
    ) async -> RemoteMarkdownSnapshot? {
        let output = await fetchOutput(for: reference)
        if let output, output.count <= DocumentURLValidator.maxFileSizeBytes {
            return write(output, for: reference)
        }
        return cachedSnapshot(for: reference)
            ?? write(Data(failureMarkdown(for: reference).utf8), for: reference)
    }

    func pruneUnreferencedSnapshots(keeping referencedFileURLs: Set<URL>) {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: cacheDirectoryURL.path)) == nil else {
            return
        }
        guard ((try? cacheDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true else {
            return
        }
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: cacheDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
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
        if let fetchOverride {
            return await fetchOverride(reference)
        }
        return await runner.run(
            arguments: Self.sshArguments(target: reference.sshTarget, path: reference.remotePath),
            inDirectory: FileManager.default.currentDirectoryPath
        )
    }

    static func sshArguments(target: String, path: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "NumberOfPasswordPrompts=0",
            "--",
            target,
            remoteReadCommand(path: path),
        ]
    }

    private static func remoteReadCommand(path: String) -> String {
        let quotedPath = Self.shellSingleQuoted(path)
        return
            "p=\(quotedPath); case \"$p\" in \"~/\"*) p=\"$HOME/${p#~/}\";; esac; [ -f \"$p\" ] || exit 1; size=$(wc -c < \"$p\") || exit 1; [ \"$size\" -le \(DocumentURLValidator.maxFileSizeBytes) ] || exit 2; cat -- \"$p\""
    }

    private func write(
        _ content: Data,
        for reference: RemoteMarkdownReference
    ) -> RemoteMarkdownSnapshot? {
        do {
            try fileManager.createOwnerOnlyDirectory(at: cacheDirectoryURL)
            try fileManager.setOwnerOnlyPermissions(onDirectoryAt: cacheDirectoryURL)
            let fileURL = cacheFileURL(for: reference)
            try content.write(to: fileURL, options: .atomic)
            // The chmod follows symlinks; safe only because the atomic write
            // above just replaced any pre-planted link at this path.
            try fileManager.setOwnerOnlyPermissions(onFileAt: fileURL)
            return RemoteMarkdownSnapshot(fileURL: fileURL, identity: reference.identity)
        } catch {
            return nil
        }
    }

    private func cachedSnapshot(
        for reference: RemoteMarkdownReference
    ) -> RemoteMarkdownSnapshot? {
        let fileURL = cacheFileURL(for: reference)
        guard ((try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true else {
            return nil
        }
        return RemoteMarkdownSnapshot(fileURL: fileURL, identity: reference.identity)
    }

    private func cacheFileURL(for reference: RemoteMarkdownReference) -> URL {
        cacheDirectoryURL.appending(path: cacheFileName(for: reference))
    }

    func cacheFileName(for reference: RemoteMarkdownReference) -> String {
        let ext = (reference.remotePath as NSString).pathExtension.lowercased()
        return "\(Self.stableHash(Self.cacheIdentityKey(reference.identity))).\(ext)"
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

    private static func cacheIdentityKey(_ identity: ResourceIdentity) -> String {
        guard case .remote(let target) = identity.location else {
            preconditionFailure("Remote Markdown cache keys require a remote identity")
        }
        return ["remote", target.user, target.host, identity.path.rawValue]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
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
