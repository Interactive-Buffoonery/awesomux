import AwesoMuxCore
import DesignSystem
import SwiftUI

struct DocumentFileBrowserView: View {
    let rootURL: URL?
    let currentFileURL: URL
    let onOpen: (URL) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var files: [MarkdownFileEntry] = []
    @State private var currentDirectory = ""
    @State private var refusal: String?
    @State private var isLoading = false
    @State private var refreshGeneration = 0
    @State private var activeLoadID: UUID?
    @Environment(\.awAccent) private var accentResolver

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }

    private var rootTaskID: String {
        "\(rootURL?.standardizedFileURL.path ?? "missing-root")#\(refreshGeneration)"
    }

    private var visibleHits: [MarkdownFileSearchHit] {
        MarkdownFileSearch.hits(in: files, query: query)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var directoryContents: MarkdownDirectoryContents {
        MarkdownDirectoryBrowser.contents(in: files, at: currentDirectory)
    }

    private var rootDisplayName: String {
        guard let rootURL else { return "Folder" }
        return rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
    }

    private var refreshHelp: String {
        guard let rootURL else {
            return "Refresh Markdown files"
        }
        return "Refresh Markdown files in \(rootURL.path)"
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Rectangle()
                .fill(Color.aw.border2.opacity(0.7))
                .frame(height: 0.5)
            if let refusal {
                refusalNotice(refusal)
                Rectangle()
                    .fill(Color.aw.border2.opacity(0.45))
                    .frame(height: 0.5)
            }
            if rootURL != nil && !isSearching {
                directoryBar
                Rectangle()
                    .fill(Color.aw.border2.opacity(0.45))
                    .frame(height: 0.5)
            }
            browserContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.aw.surface.terminal)
        .task(id: rootTaskID) {
            await reloadFiles(rootURL: rootURL)
        }
        // A refusal names one file in one place; carrying it into a different
        // folder or a different search would attach it to whatever the user is
        // looking at now.
        .onChange(of: currentDirectory) { refusal = nil }
        .onChange(of: query) { refusal = nil }
        .accessibilityElement(children: .contain)
    }

    private func refusalNotice(_ message: String) -> some View {
        // The composited (opaque) tint keeps the notice legible under Reduce
        // Transparency, and its foreground is contrast-checked against that
        // exact composite rather than against the bare status color.
        let base = Color.aw.surface.terminal
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.aw.status.needs)
                .accessibilityHidden(true)
            Text(message)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.status.tintForeground(for: .needs, over: base))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aw.status.tintBackground(for: .needs, over: base))
        .accessibilityElement(children: .combine)
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aw.text2)
            .background(Color.aw.surface.chrome2.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.aw.border2.opacity(0.8), lineWidth: 0.5)
            }
            .help("Back to document")
            .accessibilityLabel("Back to document")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.aw.text3)
                TextField("Search Markdown", text: $query)
                    .textFieldStyle(.plain)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text)
                    .accessibilityLabel("Search Markdown files")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.aw.surface.chrome.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.aw.border2.opacity(0.8), lineWidth: 0.5)
            }

            refreshButton

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading Markdown files")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(DocumentPaneChrome.barBackground(edge: .bottom))
    }

    private var refreshButton: some View {
        Button {
            refreshGeneration += 1
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.aw.text2)
        .background(Color.aw.surface.chrome2.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.aw.border2.opacity(0.8), lineWidth: 0.5)
        }
        .help(refreshHelp)
        .accessibilityLabel("Refresh Markdown files")
        .disabled(rootURL == nil || isLoading)
        .opacity(rootURL == nil ? 0.45 : 1)
    }

    private var directoryBar: some View {
        HStack(spacing: 6) {
            Button {
                currentDirectory = ""
            } label: {
                Label(rootDisplayName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .awFont(AwFont.Mono.meta)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(currentDirectory.isEmpty ? accentColor : Color.aw.text2)
            .help(rootURL?.path ?? rootDisplayName)
            .accessibilityLabel("Root folder \(rootDisplayName)")

            ForEach(MarkdownDirectoryBrowser.breadcrumbs(for: currentDirectory)) { crumb in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
                Button {
                    currentDirectory = crumb.relativePath
                } label: {
                    Text(crumb.name)
                        .awFont(AwFont.Mono.meta)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(crumb.relativePath == currentDirectory ? accentColor : Color.aw.text2)
                .accessibilityLabel("Folder \(crumb.name)")
            }

            Spacer(minLength: 8)

            if let parent = directoryContents.parentRelativePath {
                Button {
                    currentDirectory = parent
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.aw.text2)
                .background(Color.aw.surface.chrome2.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.aw.border2.opacity(0.8), lineWidth: 0.5)
                }
                .help("Parent folder")
                .accessibilityLabel("Parent folder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aw.surface.chrome.opacity(0.42))
    }

    @ViewBuilder
    private var browserContent: some View {
        if rootURL == nil {
            DocumentFileBrowserEmptyState(
                systemImage: "folder.badge.questionmark",
                title: "No directory",
                detail: String(
                    localized: "This document's terminal has not reported a local directory.",
                    comment: "Empty-state detail shown when a document's associated terminal has no local directory"
                )
            )
        } else if !isLoading && files.isEmpty {
            DocumentFileBrowserEmptyState(
                systemImage: "doc.text.magnifyingglass",
                title: "No Markdown files",
                detail: rootURL?.path ?? ""
            )
        } else if isSearching && !isLoading && visibleHits.isEmpty {
            DocumentFileBrowserEmptyState(
                systemImage: "magnifyingglass",
                title: "No matching files",
                detail: query
            )
        } else if isSearching {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleHits, id: \.entry.id) { hit in
                        DocumentFileBrowserFileRow(
                            entry: hit.entry,
                            isCurrent: hit.entry.url.standardizedFileURL
                                == currentFileURL.standardizedFileURL,
                            action: {
                                open(hit.entry)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        } else if directoryContents.directories.isEmpty && directoryContents.files.isEmpty {
            DocumentFileBrowserEmptyState(
                systemImage: "folder",
                title: "Empty folder",
                detail: currentDirectory.isEmpty ? rootDisplayName : currentDirectory
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(directoryContents.directories) { directory in
                        DocumentFileBrowserDirectoryRow(
                            directory: directory,
                            action: {
                                currentDirectory = directory.relativePath
                            }
                        )
                    }
                    ForEach(directoryContents.files, id: \.id) { entry in
                        DocumentFileBrowserFileRow(
                            entry: entry,
                            isCurrent: entry.url.standardizedFileURL
                                == currentFileURL.standardizedFileURL,
                            action: {
                                open(entry)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// `onOpen` replaces the document tab in place, destroying the current
    /// file's association and scroll context before the pane discovers it
    /// can't render the new one. Anything that would be rejected must be
    /// reported *instead of* opening, not after.
    @MainActor
    private func open(_ entry: MarkdownFileEntry) {
        guard let message = Self.refusalMessage(forOpening: entry.url) else {
            refusal = nil
            onOpen(entry.url)
            return
        }
        refusal = message
        // The notice is a visual change with no focus move, so VoiceOver would
        // otherwise report nothing at all for a click that did nothing.
        TerminalAccessibilityAnnouncer.announce(message, priority: .high)
    }

    /// Re-stats `url` at click time and returns the reason it can't be opened.
    ///
    /// The enumerated size is a snapshot: agent-written documents grow between
    /// the listing and the click, which is exactly the race the cap makes
    /// routine. Only size is checked — the enumerator already filters by
    /// extension and yields local file URLs.
    static func refusalMessage(forOpening url: URL) -> String? {
        // `FileManager`, not `url.resourceValues(forKeys:)`: a URL caches the
        // resource values it has already been asked for, so re-reading through
        // it can hand back the enumeration-time size — the exact staleness this
        // check exists to defeat.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue
        guard DocumentURLValidator.reject(url, fileSize: size) == .tooLarge else { return nil }
        let quoted = "\u{201C}\(url.lastPathComponent)\u{201D}"
        // Deliberately the same sentence the document pane uses for the same
        // rejection, so the two surfaces share one catalog entry and one
        // wording.
        return String(
            localized: "Can't open \(quoted): file exceeds the \(DocumentURLValidator.maxFileSizeMegabytes) MB size limit.",
            comment: "Document pane error; first placeholder is the quoted file name, second is the cap in whole megabytes")
    }

    /// Built here rather than in the row so the size state a sighted user reads
    /// off the marker is provably the same state VoiceOver speaks.
    static func fileRowAccessibilityLabel(entry: MarkdownFileEntry, isCurrent: Bool) -> String {
        if entry.exceedsSizeCap {
            let size = formattedSize(entry.fileSizeBytes)
            let cap = DocumentURLValidator.maxFileSizeMegabytes
            return String(
                localized: "Too large to open, \(size), over the \(cap) MB limit, \(entry.relativePath)",
                comment:
                    "VoiceOver label for a Markdown file the viewer can't open; placeholders are the file size, the cap in whole megabytes, and the path"
            )
        }
        if isCurrent {
            return "Current document, \(entry.relativePath)"
        }
        return "Open \(entry.relativePath)"
    }

    static func formattedSize(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @MainActor
    private func reloadFiles(rootURL: URL?) async {
        let loadID = UUID()
        activeLoadID = loadID
        refusal = nil

        guard let rootURL else {
            files = []
            currentDirectory = ""
            isLoading = false
            activeLoadID = nil
            return
        }

        isLoading = true
        currentDirectory = ""
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            MarkdownFileEnumerator.enumerate(root: rootURL)
        }.value

        guard activeLoadID == loadID else { return }
        defer {
            if activeLoadID == loadID {
                isLoading = false
                activeLoadID = nil
            }
        }
        guard !Task.isCancelled else { return }
        files = loadedFiles
    }
}

private struct DocumentFileBrowserDirectoryRow: View {
    let directory: MarkdownDirectoryEntry
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.awAccent) private var accentResolver

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(directory.name)
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                        .lineLimit(1)
                    Text(directory.relativePath)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? Color.aw.surface.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open folder \(directory.relativePath)")
    }
}

private struct DocumentFileBrowserFileRow: View {
    let entry: MarkdownFileEntry
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.awAccent) private var accentResolver

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }
    private var accentSoftColor: Color { Color.aw.accentSoft(accentResolver.accent) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isCurrent ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? accentColor : Color.aw.text3)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileName)
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                        .lineLimit(1)
                    Text(entry.relativePath)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // Shown rather than filtered out: a user who can't find their
                // file has no error to read, which is worse than a clear one.
                if entry.exceedsSizeCap {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(DocumentFileBrowserView.formattedSize(entry.fileSizeBytes))
                            .awFont(AwFont.Mono.meta)
                    }
                    .foregroundStyle(Color.aw.status.needs)
                    .accessibilityHidden(true)
                }

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowBackground: Color {
        if isCurrent {
            return accentSoftColor.opacity(isHovering ? 0.85 : 0.58)
        }
        return isHovering ? Color.aw.surface.hover : Color.clear
    }

    private var accessibilityLabel: String {
        DocumentFileBrowserView.fileRowAccessibilityLabel(entry: entry, isCurrent: isCurrent)
    }
}

private struct DocumentFileBrowserEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.aw.text3)
            Text(title)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
            if !detail.isEmpty {
                Text(detail)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
