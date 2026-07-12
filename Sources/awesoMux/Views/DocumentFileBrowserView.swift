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
        .accessibilityElement(children: .contain)
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
                                onOpen(hit.entry.url)
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
                                onOpen(entry.url)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @MainActor
    private func reloadFiles(rootURL: URL?) async {
        let loadID = UUID()
        activeLoadID = loadID

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
        if isCurrent {
            return "Current document, \(entry.relativePath)"
        }
        return "Open \(entry.relativePath)"
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
