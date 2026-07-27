import AwesoMuxConfig
import AwesoMuxCore
import CryptoKit
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
        let candidatePath = MarkdownLinkIntercept.documentCandidatePath(from: payload)
        guard !candidatePath.isEmpty,
            let parsed = URL(string: candidatePath)
        else {
            return nil
        }
        if parsed.scheme == nil {
            return candidatePath
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

/// Why a remote read produced a generated page instead of the file. Carried on
/// the outcome rather than living only inside the page body: the page is one
/// surface among several (the VoiceOver announcement is another), and a reader
/// who is told "fetch failed" for a permanently oversize file retries a doomed
/// eight-second round trip.
enum RemoteMarkdownFailureReason: Equatable, Sendable {
    case oversize
    case notFound
    case connection
}

enum RemoteMarkdownFetchOutcome: Equatable, Sendable {
    case fresh(RemoteMarkdownSnapshot)
    case cached(RemoteMarkdownSnapshot)
    case failureDocument(RemoteMarkdownSnapshot, reason: RemoteMarkdownFailureReason)

    var snapshot: RemoteMarkdownSnapshot {
        switch self {
        case .fresh(let snapshot), .cached(let snapshot), .failureDocument(let snapshot, _):
            snapshot
        }
    }
}

private actor RemoteMarkdownFetchCoordinator {
    struct Key: Hashable, Sendable {
        let identity: ResourceIdentity
        let cacheDirectoryPath: String
    }

    static let shared = RemoteMarkdownFetchCoordinator()

    private var inFlight: [Key: Task<RemoteMarkdownFetchOutcome?, Never>] = [:]

    func value(
        for key: Key,
        onCoalesced: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async -> RemoteMarkdownFetchOutcome?
    ) async -> RemoteMarkdownFetchOutcome? {
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
    var fetchOverride: (@Sendable (RemoteMarkdownReference) async -> BoundedCommandResult)?
    var onCoalescedFetch: (@Sendable () async -> Void)?

    func fetch(_ reference: RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? {
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
    ) async -> RemoteMarkdownFetchOutcome? {
        let result = await fetchOutput(for: reference)
        if case .success(let output) = result, output.count <= DocumentURLValidator.maxFileSizeBytes {
            return write(output, at: cacheFileURL(for: reference), for: reference)
                .map(RemoteMarkdownFetchOutcome.fresh)
        }
        // Retained content wins over an explanation, so a file that cached
        // successfully and later grew past the cap never renders the oversize
        // page — the user sees the stale copy with no word of why it stopped
        // refreshing. The agreed surface for that is a banner over the retained
        // content, which does not exist yet; deliberately not fixed by
        // reordering these two branches.
        if let cached = cachedSnapshot(for: reference) {
            return .cached(cached)
        }
        let reason = Self.failureReason(for: result)
        let markdown = failureMarkdown(for: reference, reason: reason)
        return write(Data(markdown.utf8), at: failureFileURL(for: reference), for: reference)
            .map { .failureDocument($0, reason: reason) }
    }

    /// Exit statuses the remote script uses to report what it found. Above the
    /// range `/bin/sh` claims for its own syntax and startup failures (1, 2,
    /// 126, 127) so a remote with a broken shell cannot be misread as a verdict
    /// about the file, and clear of 255, which ssh reserves for its own
    /// connection failures. Interpolated into `remoteReadCommand` and matched in
    /// `failureReason` so the shell and Swift halves of the contract cannot
    /// drift apart.
    enum RemoteReadExit {
        static let fileNotReadable: Int32 = 20
        static let fileTooLarge: Int32 = 21
    }

    /// No `default:` — a new `BoundedCommandResult` case must break this build
    /// rather than silently landing in "connection problem".
    private static func failureReason(for result: BoundedCommandResult) -> RemoteMarkdownFailureReason {
        switch result {
        case .nonZeroExit(RemoteReadExit.fileTooLarge), .outputTruncated:
            // The script exits `fileTooLarge` when `wc -c` already sees an
            // oversize file, but the file can also grow between that check and
            // the `cat` that follows: the shell then exits 0 while the extra
            // bytes trip the runner's `maxFileSizeBytes + 1` cap. A capped read
            // is the same "too large" answer, not a connectivity failure.
            .oversize
        case .timedOut(let outputTruncated):
            // Same race, one step further: the read can also blow the cap and
            // then miss the deadline. The runner classifies that as a timeout,
            // but it already proved the output exceeded the cap.
            outputTruncated ? .oversize : .connection
        case .success(let data):
            // Only reachable over the cap; the caller took the under-cap case.
            data.count > DocumentURLValidator.maxFileSizeBytes ? .oversize : .connection
        case .nonZeroExit(RemoteReadExit.fileNotReadable):
            // Reachable only once ssh connected and a remote shell ran, so this
            // is definitively the file, not the network.
            .notFound
        case .nonZeroExit, .executableNotFound, .spawnFailure, .outputNotDrained:
            .connection
        }
    }

    func pruneUnreferencedSnapshots(keeping referencedFileURLs: Set<URL>) {
        guard let cacheDirectoryURL = validatedCacheDirectory(createIfMissing: false) else { return }
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

    private func fetchOutput(for reference: RemoteMarkdownReference) async -> BoundedCommandResult {
        if let fetchOverride {
            return await fetchOverride(reference)
        }
        // The full result, not `completeData`: only `.success` is the file, but
        // the other cases are what tell the failure document whether this was an
        // oversize file or a connection problem. The runner's cap is
        // maxFileSizeBytes + 1 so an oversize remote surfaces as truncation
        // rather than a silently short body.
        return await runner.runDetailed(
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
        let missing = RemoteReadExit.fileNotReadable
        let tooLarge = RemoteReadExit.fileTooLarge
        return
            "p=\(quotedPath); case \"$p\" in \"~/\"*) p=\"$HOME/${p#~/}\";; esac; [ -f \"$p\" ] || exit \(missing); size=$(wc -c < \"$p\") || exit \(missing); [ \"$size\" -le \(DocumentURLValidator.maxFileSizeBytes) ] || exit \(tooLarge); cat -- \"$p\""
    }

    private func write(
        _ content: Data,
        at fileURL: URL,
        for reference: RemoteMarkdownReference
    ) -> RemoteMarkdownSnapshot? {
        do {
            guard validatedCacheDirectory(createIfMissing: true) != nil else { return nil }
            try fileManager.writeOwnerOnlyFile(at: fileURL, contents: content)
            return RemoteMarkdownSnapshot(fileURL: fileURL, identity: reference.identity)
        } catch {
            return nil
        }
    }

    private func cachedSnapshot(
        for reference: RemoteMarkdownReference
    ) -> RemoteMarkdownSnapshot? {
        guard validatedCacheDirectory(createIfMissing: false) != nil else { return nil }
        let fileURL = cacheFileURL(for: reference)
        guard ((try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true else {
            return nil
        }
        guard !Self.isLegacyFailurePage(at: fileURL) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return RemoteMarkdownSnapshot(fileURL: fileURL, identity: reference.identity)
    }

    /// Builds shipped before the failure page moved to its own name wrote that
    /// page to the snapshot path, where this cache lookup would keep serving it
    /// back — labelled as a point-in-time copy of the user's file — forever.
    /// The new hash orphans most of those entries by renaming the slot, but the
    /// invariant is "app-authored copy is never a snapshot", so it is enforced
    /// here rather than left to that side effect. Sniffing the app-authored
    /// preamble is the only available signal; a real document that opens with
    /// those exact two lines is merely re-fetched.
    private static func isLegacyFailurePage(at fileURL: URL) -> Bool {
        let preamble = Data("# Couldn't fetch remote Markdown\n\nawesoMux could not read ".utf8)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: preamble.count)) == preamble
    }

    private func validatedCacheDirectory(createIfMissing: Bool) -> URL? {
        if (try? fileManager.destinationOfSymbolicLink(atPath: cacheDirectoryURL.path)) != nil {
            return nil
        }
        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            guard createIfMissing else { return nil }
            do {
                try fileManager.createOwnerOnlyDirectory(at: cacheDirectoryURL)
            } catch {
                return nil
            }
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: cacheDirectoryURL.path)) == nil,
            ((try? cacheDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
        else {
            return nil
        }
        if createIfMissing {
            do {
                try fileManager.setOwnerOnlyPermissions(onDirectoryAt: cacheDirectoryURL)
            } catch {
                return nil
            }
        }
        return cacheDirectoryURL
    }

    private func cacheFileURL(for reference: RemoteMarkdownReference) -> URL {
        cacheDirectoryURL.appending(path: cacheFileName(for: reference))
    }

    func cacheFileName(for reference: RemoteMarkdownReference) -> String {
        let ext = (reference.remotePath as NSString).pathExtension.lowercased()
        return "\(Self.stableHash(Self.cacheIdentityKey(reference.identity))).\(ext)"
    }

    private func failureFileURL(for reference: RemoteMarkdownReference) -> URL {
        cacheDirectoryURL.appending(path: failureFileName(for: reference))
    }

    /// Deliberately not `cacheFileName`: an app-generated failure page written to
    /// the snapshot path would be found by `cachedSnapshot` on the next failed
    /// fetch and presented to the user as a point-in-time copy of their file.
    /// The extension is always `md` because the page is app-authored Markdown,
    /// whatever extension the remote file carried.
    private func failureFileName(for reference: RemoteMarkdownReference) -> String {
        "\(Self.stableHash(Self.cacheIdentityKey(reference.identity))).failure.md"
    }

    private func failureMarkdown(
        for reference: RemoteMarkdownReference,
        reason: RemoteMarkdownFailureReason
    ) -> String {
        // The code-span delimiters stay in Swift, outside the localized key.
        // `markdownInlineCode` seals an attacker-influenced origin by stripping
        // backticks and nothing else, which only holds while a balanced pair
        // surrounds it — a translation that dropped or unbalanced them would
        // un-seal the value, and `[`, `]`, `(`, `)` all survive
        // `UnicodeHygiene.containsUnsafePathScalars`, so a link could be
        // injected into a page the user is primed to trust.
        let origin = "`\(Self.markdownInlineCode(reference.origin))`"
        switch reason {
        case .oversize:
            // Shares the document pane's rejection key: same fact, same shape,
            // and the delimiter around the first argument is the caller's, not
            // the key's. A second translation unit would only let the two
            // statements of one cap drift.
            return """
                # \(String(localized: "Remote Markdown is too large", comment: "Heading of the generated page shown when a remote Markdown file exceeds the size cap"))

                \(String(localized: "Can't open \(origin): file exceeds the \(DocumentURLValidator.maxFileSizeMegabytes) MB size limit.", comment: "Document pane error; first placeholder is the quoted file name, second is the cap in whole megabytes"))
                """
        case .notFound:
            return """
                # \(String(localized: "Remote Markdown file not found", comment: "Heading of the generated page shown when a remote Markdown file is missing or unreadable"))

                \(String(localized: "awesoMux connected to the host but could not read \(origin).", comment: "Body of the missing remote Markdown page; the placeholder is the remote origin"))

                \(String(localized: "Check that the file still exists at that path and that your account can read it.", comment: "Remediation line of the missing remote Markdown page"))
                """
        case .connection:
            return """
                # \(String(localized: "Couldn't fetch remote Markdown", comment: "Heading of the generated page shown when a remote Markdown fetch fails"))

                \(String(localized: "awesoMux could not read \(origin) using SSH.", comment: "Body of the failed remote Markdown fetch page; the placeholder is the remote origin"))

                \(String(localized: "Check that the host is reachable and your SSH config can connect without an interactive password prompt.", comment: "Remediation line of the failed remote Markdown fetch page"))
                """
        }
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

    /// Must be preimage-resistant, not merely well-distributed: the remote path
    /// reaches here from an OSC payload that any process in the SSH'd pane can
    /// emit. 64-bit FNV-1a is trivially invertible, so an attacker could solve
    /// for a path whose hash lands on a victim path's cache slot, have their
    /// content written there, and see it served back as "Read-only snapshot
    /// from <victim path>". 128 bits of SHA-256 is far past birthday reach for
    /// a per-user cache directory.
    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
