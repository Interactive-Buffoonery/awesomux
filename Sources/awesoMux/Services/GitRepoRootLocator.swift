import Foundation

/// Walks ancestor directories to the first one containing a `.git` entry.
/// Extracted from the path bar's `PathInfo` so the path bar and the
/// layout-preset store (`LayoutPresetStore`) resolve the same project root —
/// two walkers would inevitably drift on edge cases.
///
/// This locates a root only; it deliberately does NOT validate the `.git`
/// entry. Callers that go on to READ from the git admin directory must run the
/// path bar's validated-gitdir resolution; callers that only need "where does
/// this project start" (preset placement) use the located root directly.
enum GitRepoRootLocator {
    static func repoRootURL(
        startingAt url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate = url.standardizedFileURL

        while true {
            let gitPath = candidate.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }
    }
}
