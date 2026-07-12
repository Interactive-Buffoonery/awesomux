import AwesoMuxCore
import Foundation
import UnicodeHygiene

struct SidebarDuplicateDisambiguation: Equatable {
    let ordinal: Int
    let total: Int

    var visibleLabel: String {
        "\(ordinal) of \(total)"
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

    static func disambiguationBySessionID(
        for entries: [SidebarGroupEntry]
    ) -> [TerminalSession.ID: SidebarDuplicateDisambiguation] {
        var idsByKey: [VisibleIdentityKey: [TerminalSession.ID]] = [:]

        for entry in entries {
            for sessionEntry in entry.sessions {
                let session = sessionEntry.session
                idsByKey[
                    VisibleIdentityKey(
                        groupID: entry.group.id,
                        title: UnicodeHygiene.sanitize(session.title, maxLength: identityKeyMaxLength),
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

    /// Identity is scoped to the owning group: two sessions with the same title
    /// and location in *different* groups are already separated by the group header,
    /// so they get no ordinal. Group-scoping also means collapsed groups can't
    /// skew a visible group's "N of M" count. Title/location are sanitized so a
    /// homoglyph/zero-width variant can't masquerade as a distinct row.
    private struct VisibleIdentityKey: Hashable {
        var groupID: SessionGroup.ID
        var title: String
        var location: String
    }
}
