import AwesoMuxCore
import Foundation
import UnicodeHygiene

struct SidebarDuplicateDisambiguation: Equatable {
    let ordinal: Int
    let total: Int

    var visibleLabel: String {
        "\(ordinal)"
    }

    var accessibilitySuffix: String {
        // Worded to not collide with the row's own "Workspace N of M" value —
        // "copy N of M" reads distinctly from a positional ordinal in VoiceOver.
        "duplicate workspace, copy \(ordinal) of \(total)"
    }
}

enum SidebarDuplicateDisambiguator {
    /// Caps used only to normalize the identity key for comparison; generous
    /// enough not to truncate real titles/paths.
    private static let identityKeyMaxLength = 512

    /// - Parameter titles: resolved workspace titles from the sidebar's coarse
    ///   channel (`SessionStore.sidebarResolvedTitles()`). Compare the rendered
    ///   title (issue #327), treating spellings of its own local folder as equal;
    ///   an absent entry falls back to storage.
    static func disambiguationBySessionID(
        for entries: [SidebarGroupEntry],
        titles: [TerminalSession.ID: String] = [:],
        localHostnames: Set<String> = []
    ) -> [TerminalSession.ID: SidebarDuplicateDisambiguation] {
        var idsByKey: [VisibleIdentityKey: [TerminalSession.ID]] = [:]

        for entry in entries {
            for sessionEntry in entry.sessions {
                let session = sessionEntry.session
                idsByKey[
                    VisibleIdentityKey(
                        groupID: entry.group.id,
                        title: titleIdentity(
                            titles[session.id] ?? session.title,
                            session: session,
                            localHostnames: localHostnames
                        ),
                        location: UnicodeHygiene.sanitize(
                            session.sidebarLocation.identityText,
                            maxLength: identityKeyMaxLength
                        )
                    ),
                    default: []
                ].append(session.id)
            }
        }

        var result: [TerminalSession.ID: SidebarDuplicateDisambiguation] = [:]
        for ids in idsByKey.values where ids.count > 1 {
            for (offset, id) in ids.enumerated() {
                result[id] = SidebarDuplicateDisambiguation(
                    ordinal: offset + 1,
                    total: ids.count
                )
            }
        }

        return result
    }

    private static func titleIdentity(
        _ rawTitle: String,
        session: TerminalSession,
        localHostnames: Set<String>
    ) -> TitleIdentity {
        let title = UnicodeHygiene.sanitize(rawTitle, maxLength: identityKeyMaxLength)
        guard session.sidebarLocation.kind == .local else { return .literal(title) }
        let directory = session.activePane?.workingDirectory ?? session.workingDirectory
        let spellings = [
            directory,
            TerminalSession.abbreviatedWorkingDirectory(directory),
            (directory as NSString).lastPathComponent,
        ]
        var folderTitle = title
        if RemoteSessionDetector.detect(title: title, localNames: localHostnames) == .local,
            let colon = title.firstIndex(of: ":")
        {
            folderTitle = String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let matchesDirectory = spellings.contains {
            UnicodeHygiene.sanitize($0, maxLength: identityKeyMaxLength) == folderTitle
        }
        return matchesDirectory ? .workingDirectory : .literal(title)
    }

    private enum TitleIdentity: Hashable {
        case workingDirectory
        case literal(String)
    }

    /// Identity is scoped to the owning group: two sessions with equivalent titles
    /// and location in *different* groups are already separated by the group header,
    /// so they get no ordinal. Group-scoping also means collapsed groups can't
    /// skew a visible group's "N of M" count. Title/location are sanitized so a
    /// homoglyph/zero-width variant can't masquerade as a distinct row.
    private struct VisibleIdentityKey: Hashable {
        var groupID: SessionGroup.ID
        var title: TitleIdentity
        var location: String
    }
}
