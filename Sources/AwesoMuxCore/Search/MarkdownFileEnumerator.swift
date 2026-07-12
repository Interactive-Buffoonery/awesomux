import Foundation

public struct MarkdownFileEntry: Equatable, Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public let fileName: String

    public var id: String {
        url.standardizedFileURL.path
    }

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        self.fileName = url.lastPathComponent
    }
}

public enum MarkdownFileEnumerator {
    public struct Options: Equatable, Sendable {
        public var maxDepth: Int
        public var maxCount: Int
        public var skippedDirectoryNames: Set<String>

        public init(
            maxDepth: Int = 5,
            maxCount: Int = 500,
            skippedDirectoryNames: Set<String> = [".git", "node_modules", "vendor", ".build", ".swiftpm", ".worktrees"]
        ) {
            self.maxDepth = max(0, maxDepth)
            self.maxCount = max(0, maxCount)
            self.skippedDirectoryNames = skippedDirectoryNames
        }
    }

    public static func enumerate(
        root: URL,
        options: Options = Options(),
        fileManager: FileManager = .default
    ) -> [MarkdownFileEntry] {
        guard options.maxCount > 0 else { return [] }

        let rootURL = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var entries: [MarkdownFileEntry] = []
        collectMarkdownFiles(
            in: rootURL,
            root: rootURL,
            depth: 0,
            options: options,
            fileManager: fileManager,
            entries: &entries
        )
        return entries
    }

    private static func collectMarkdownFiles(
        in directory: URL,
        root: URL,
        depth: Int,
        options: Options,
        fileManager: FileManager,
        entries: inout [MarkdownFileEntry]
    ) {
        guard entries.count < options.maxCount else { return }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )) ?? []

        for child in children.sorted(by: compareURLsByPath) {
            guard entries.count < options.maxCount else { return }

            let values = try? child.resourceValues(forKeys: resourceKeys)
            if values?.isSymbolicLink == true {
                continue
            }

            if values?.isDirectory == true {
                guard depth < options.maxDepth,
                      !options.skippedDirectoryNames.contains(child.lastPathComponent)
                else {
                    continue
                }
                collectMarkdownFiles(
                    in: child,
                    root: root,
                    depth: depth + 1,
                    options: options,
                    fileManager: fileManager,
                    entries: &entries
                )
                continue
            }

            guard values?.isRegularFile == true,
                  DocumentURLValidator.allowedExtensions.contains(child.pathExtension.lowercased())
            else {
                continue
            }

            entries.append(MarkdownFileEntry(
                url: child.standardizedFileURL,
                relativePath: relativePath(for: child.standardizedFileURL, root: root)
            ))
        }
    }

    private static func compareURLsByPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path
        let filePath = url.path

        guard filePath.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.isEmpty ? url.lastPathComponent : relative
    }
}

public struct MarkdownFileSearchHit: Equatable, Sendable {
    public let entry: MarkdownFileEntry
    public let score: Int

    public init(entry: MarkdownFileEntry, score: Int) {
        self.entry = entry
        self.score = score
    }
}

public enum MarkdownFileSearch {
    public static func hits(
        in entries: [MarkdownFileEntry],
        query: String
    ) -> [MarkdownFileSearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return entries.map { MarkdownFileSearchHit(entry: $0, score: 0) }
        }

        return entries.compactMap { entry in
            let relativeScore = FuzzyMatcher.match(
                query: trimmedQuery,
                in: entry.relativePath
            )?.score
            let fileNameScore = FuzzyMatcher.match(
                query: trimmedQuery,
                in: entry.fileName
            ).map { $0.score + 4 }
            guard let score = [relativeScore, fileNameScore].compactMap({ $0 }).max() else {
                return nil
            }
            return MarkdownFileSearchHit(entry: entry, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.entry.relativePath.count != rhs.entry.relativePath.count {
                return lhs.entry.relativePath.count < rhs.entry.relativePath.count
            }
            return lhs.entry.relativePath.localizedStandardCompare(rhs.entry.relativePath)
                == .orderedAscending
        }
    }
}

public struct MarkdownDirectoryEntry: Equatable, Identifiable, Sendable {
    public let relativePath: String
    public let name: String

    public var id: String { relativePath }

    public init(relativePath: String, name: String) {
        self.relativePath = relativePath
        self.name = name
    }
}

public struct MarkdownDirectoryContents: Equatable, Sendable {
    public let relativePath: String
    public let parentRelativePath: String?
    public let directories: [MarkdownDirectoryEntry]
    public let files: [MarkdownFileEntry]

    public init(
        relativePath: String,
        parentRelativePath: String?,
        directories: [MarkdownDirectoryEntry],
        files: [MarkdownFileEntry]
    ) {
        self.relativePath = relativePath
        self.parentRelativePath = parentRelativePath
        self.directories = directories
        self.files = files
    }
}

public enum MarkdownDirectoryBrowser {
    public static func contents(
        in entries: [MarkdownFileEntry],
        at relativeDirectory: String
    ) -> MarkdownDirectoryContents {
        let directory = normalizedDirectory(relativeDirectory)
        let directoryComponents = directoryComponents(directory)
        var childDirectories: [String: MarkdownDirectoryEntry] = [:]
        var files: [MarkdownFileEntry] = []

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard components.count > directoryComponents.count,
                  components.starts(with: directoryComponents) else {
                continue
            }

            let remaining = components.dropFirst(directoryComponents.count)
            if remaining.count == 1 {
                files.append(entry)
                continue
            }

            guard let childName = remaining.first else { continue }
            let childRelativePath = (directoryComponents + [childName]).joined(separator: "/")
            childDirectories[childRelativePath] = MarkdownDirectoryEntry(
                relativePath: childRelativePath,
                name: childName
            )
        }

        return MarkdownDirectoryContents(
            relativePath: directory,
            parentRelativePath: parentDirectory(directory),
            directories: childDirectories.values.sorted(by: compareDirectories),
            files: files.sorted(by: compareFiles)
        )
    }

    public static func breadcrumbs(for relativeDirectory: String) -> [MarkdownDirectoryEntry] {
        let components = directoryComponents(normalizedDirectory(relativeDirectory))
        return components.indices.map { index in
            let path = components[...index].joined(separator: "/")
            return MarkdownDirectoryEntry(relativePath: path, name: components[index])
        }
    }

    private static func normalizedDirectory(_ relativeDirectory: String) -> String {
        relativeDirectory
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")
    }

    private static func directoryComponents(_ relativeDirectory: String) -> [String] {
        guard !relativeDirectory.isEmpty else { return [] }
        return relativeDirectory.split(separator: "/").map(String.init)
    }

    private static func parentDirectory(_ relativeDirectory: String) -> String? {
        var components = directoryComponents(relativeDirectory)
        guard !components.isEmpty else { return nil }
        components.removeLast()
        return components.joined(separator: "/")
    }

    private static func compareDirectories(
        _ lhs: MarkdownDirectoryEntry,
        _ rhs: MarkdownDirectoryEntry
    ) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func compareFiles(_ lhs: MarkdownFileEntry, _ rhs: MarkdownFileEntry) -> Bool {
        lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
    }
}
