import AwesoMuxLocalAPIAccess
import Foundation

extension LocalAPIAccessStore {
    /// Opens a store over state a previous, already released store wrote, as
    /// a relaunched app would.
    ///
    /// The authority lock outlives `relinquishAuthority()`/deinit while any
    /// concurrent test spawns a child: the spawn briefly shares every open
    /// descriptor until exec closes the close-on-exec ones, so the lock's open
    /// file description (and its `flock`) survives the close for that window
    /// and the reopen fails with `.authorityUnavailable`. A relaunched app
    /// never races its own spawns this way, so the test locks a fresh inode.
    static func reopened(
        profile: String,
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> LocalAPIAccessStore {
        try? FileManager.default.removeItem(at: supportDirectoryURL.appending(path: "LocalAPI/authority.lock"))
        return LocalAPIAccessStore(profile: profile, supportDirectoryURL: supportDirectoryURL, fileManager: fileManager)
    }
}
