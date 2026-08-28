import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - DocumentOversizePolicy

/// Decides what a completed load does when the file on disk has grown past
/// `DocumentURLValidator.maxFileSizeBytes`.
///
/// That cap is a memory ceiling, so crossing it is *routine* — an agent
/// appending to the plan file the user is reading crosses 2 MiB in normal use.
/// Swapping the mounted render for a full-pane error page at that moment
/// destroys content that is real, still on disk, and was rendered a second
/// ago, and takes the reader's scroll position with it. Retaining the last
/// whole render behind a banner is the alternative.
///
/// Pure, so the branch that matters — retain versus replace — is testable
/// without hosting the view.
enum DocumentOversizePolicy {
    enum Decision: Equatable {
        /// Assign the result and clear the banner.
        case apply
        /// A readable file arrived while the banner was up. Hold it for
        /// `settleInterval` before promoting it to the protected render.
        case settle
        /// Keep the mounted render and raise the banner over it.
        case retainRender
    }

    /// Matches `DocumentGroupView.resolveSettleInterval`, for the same reason:
    /// a non-atomic writer that truncates and rewrites leaves a valid,
    /// *under-cap prefix* on disk, and it can sit there longer than the
    /// watcher's ~100 ms debounce. Promoting that prefix immediately would
    /// leave the banner protecting half a document while the writer finishes
    /// back over cap. 500 ms outlasts that window.
    static let settleInterval: Duration = .milliseconds(500)

    /// The settle wait itself, injectable so a test can drive the hold without
    /// spending real time in it.
    ///
    /// `ContinuousClock` rather than `Task.sleep`: `script/check_test_waits.sh`
    /// rejects new `Task.sleep` in `Sources/`, because a bare sleep is neither
    /// controllable from a test nor visible to one. This is the same shape
    /// `BoundedCommandRunner` already uses for its timeout delay.
    @MainActor static var settleWait: @Sendable () async -> Void = {
        try? await ContinuousClock().sleep(for: settleInterval)
    }

    /// File paths currently held behind the banner, so a remount raises it
    /// again immediately instead of re-deriving it after a full read.
    ///
    /// This bit has to outlive the view. `.settle` — the window that keeps a
    /// non-atomic writer's under-cap prefix off screen — is only reachable
    /// while the banner is up, and the banner is `@State`. A tab switch inside
    /// that window used to remount, see no banner, and `.apply` the truncated
    /// prefix, which is worse than a flicker: `.apply` reports the render, and
    /// the `isRejectedForSize` skip does not cover a `.loaded` prefix, so the
    /// half-written document became the tab's cached seed for every later
    /// remount.
    ///
    /// Keyed by standardized path, not by tab: the file is what is over cap,
    /// and two panes can show the same one.
    ///
    /// ponytail: entries for files that never drop back under cap outlive
    /// their tab (one path string each), and a second pane opening the same
    /// over-cap file with no prior render of its own clears the entry from
    /// under the first. Add per-tab bookkeeping only if either shows up in
    /// real use.
    @MainActor private(set) static var oversizePaths: Set<String> = []

    @MainActor
    static func noteOversize(_ isOversize: Bool, path: String) {
        if isOversize {
            oversizePaths.insert(path)
        } else {
            oversizePaths.remove(path)
        }
    }

    @MainActor
    static func isOversize(path: String) -> Bool {
        oversizePaths.contains(path)
    }

    static func decide(
        result: DocumentLoader.LoadResult,
        hasPriorRender: Bool,
        isBannerShowing: Bool
    ) -> Decision {
        // Only the size rejection is retained. Every other failure means the
        // bytes behind the mounted render are gone or unreachable, and the
        // error page is the honest answer. A tab whose file is already over
        // cap on first mount has no prior render to protect, so it gets the
        // error page too.
        if result.isRejectedForSize, hasPriorRender { return .retainRender }
        if isBannerShowing, case .loaded = result { return .settle }
        return .apply
    }
}

// MARK: - RemoteSnapshotStalePolicy

/// The banner kind established by the last failed refresh of each remote
/// snapshot cache path.
///
/// Separate from `DocumentOversizePolicy.oversizePaths` rather than folded into
/// it, because the two are cleared by different things and sharing one set
/// would have them stomp each other. A remote snapshot's *local* cache file is
/// under the cap by construction — `RemoteMarkdownSnapshotFetcher` only writes
/// it when the payload fits — so `DocumentLoader` never rejects it for size,
/// `DocumentOversizePolicy.decide` never returns `.retainRender` for it, and
/// the reload path clears `oversizePaths` for that path on every successful
/// read. An entry parked there would be wiped by the next reload.
///
/// Deliberately NOT persisted, and not carried on `DocumentPane`. The banner
/// kind records why the last refresh attempt failed — knowledge that only
/// exists because an attempt was made. Session restore does not re-fetch
/// remote tabs (`SessionPersistence` only prunes the cache), so a persisted
/// value would let the app keep asserting a refresh failure it never
/// re-verified. Claiming an unverified fact is the exact shape of bug the
/// oversize work exists to remove.
///
/// The consequence is honest but real: the banner does not survive a relaunch.
/// Closing that wants re-fetching remote tabs on restore, which is its own
/// piece of work.
enum RemoteSnapshotStalePolicy {
    struct Change: Sendable {
        let path: String
        let kind: DocumentOversizeBanner.Kind?
    }

    static let didChangeNotification = Notification.Name(
        "aw.remoteSnapshotStalePolicy.didChange")

    @MainActor private(set) static var bannerKinds: [String: DocumentOversizeBanner.Kind] = [:]

    @MainActor
    static func note(_ kind: DocumentOversizeBanner.Kind?, path: String) {
        bannerKinds[path] = kind
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: Change(path: path, kind: kind)
        )
    }

    @MainActor
    static func bannerKind(path: String) -> DocumentOversizeBanner.Kind? {
        bannerKinds[path]
    }

    /// Records what a fetch just learned about this snapshot's cache path.
    ///
    /// Every cached outcome is stale, but the reason determines what the row
    /// may honestly claim. `.notFound` and `.connection` share generic refresh
    /// copy because neither explanation is true for both outcomes.
    @MainActor
    static func record(_ outcome: RemoteMarkdownFetchOutcome) {
        let path = outcome.snapshot.fileURL.standardizedFileURL.path
        switch outcome {
        case .cached(_, .oversize):
            note(.remoteStoppedRefreshing, path: path)
        case .cached(_, .notFound), .cached(_, .connection):
            note(.remoteRefreshFailed, path: path)
        case .fresh, .failureDocument:
            note(nil, path: path)
        }
    }
}

// MARK: - DocumentOversizeBanner

/// A persistent row above the document saying the file outgrew the viewer's
/// size cap and that what is on screen is the last version that fit.
///
/// Shape and lifecycle follow `BridgePermissionPromptView`: an interposed row
/// that RESERVES its height rather than overlaying the document — covering the
/// content would undo the point of keeping it — with a `status.needs` tint, a
/// bottom hairline, and a single accessibility element carrying the whole
/// message. That last part is load-bearing: the rendered markdown body is one
/// `.staticText` element labelled "Document content", so no heading inside the
/// document is reachable as structure and this row is the only signal a screen
/// reader gets that the view has stopped tracking the file.
///
/// Styling is quieter than the permission prompt (no buttons, no focus ring):
/// there is nothing to act on, so it states a fact and gets out of the way.
struct DocumentOversizeBanner: View {
    /// Three situations, one row. Each keeps the last known-good render visible
    /// while explaining why it no longer matches its source.
    enum Kind: Equatable {
        /// A local file grew past the cap while open. Comments are paused.
        case localFileGrew
        /// A remote snapshot could not be refreshed because the remote file is
        /// over the cap. Remote snapshots are already read-only
        /// (`DocumentPane.isReadOnlySnapshot`), so there is no commenting
        /// change to announce and saying so would only confuse.
        case remoteStoppedRefreshing
        /// A remote snapshot could not be refreshed because the file was not
        /// found or the connection failed. The shared copy cannot claim which.
        case remoteRefreshFailed
    }

    let fileName: String
    var kind: Kind = .localFileGrew

    // The tint is the only translucent thing on this row, and it is weakest
    // for exactly the users who asked the system to reduce translucency.
    // Same opt-out `AwPill`/`StatusDot` take, via the same helper.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(.needs)
                // Decorative — the meaning is in the container's label.
                .accessibilityHidden(true)

            Text(Self.kicker(for: kind))
                .awFont(AwFont.Mono.kicker)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
                .layoutPriority(0)

            Text(Self.detail(for: kind))
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background {
            LinearGradient(
                colors: [tint(0.22), tint(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.status.needs.opacity(0.45))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        // `.ignore`, not `.contain`: the kicker and the detail are two halves
        // of one sentence, and there is nothing here to activate.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel(fileName: fileName, kind: kind)))
    }

    /// Resolves the tint against the opaque surface the pane tree paints
    /// (`TerminalPaneView` backs the whole layout with `surface.terminal`), so
    /// Reduce Transparency gets the same appearance without the translucency.
    private func tint(_ opacity: Double) -> Color {
        reduceTransparency
            ? Color.aw.status.tintBackground(
                for: .needs, over: Color.aw.surface.terminal, opacity: opacity)
            : Color.aw.status.needs.opacity(opacity)
    }

    /// The cap is read from the validator rather than restated, so the number
    /// the user is told can never drift from the number enforced.
    ///
    /// States the read-only consequence, not just the cause: commenting going
    /// away is the change users actually collide with, and "Add Document Note"
    /// going `.disabled` reads to VoiceOver as "dimmed, button" with no reason
    /// attached. This string feeds both the visible text and the accessibility
    /// label, so saying it once covers both.
    static let detail = String(
        localized:
            "The file has grown past the \(DocumentURLValidator.maxFileSizeMegabytes) MB limit. Showing the last version that fit. Comments are paused until the file fits again.",
        comment: "Document banner shown when an open file grows past the size cap; the placeholder is the cap in whole megabytes"
    )

    /// The remote origin is deliberately NOT interpolated here. It is
    /// attacker-influenced text arriving from a terminal escape sequence, and
    /// the failure *page* has to seal it in a Markdown code span for that
    /// reason. A banner is a fixed-height row with `lineLimit(2)`, so a long or
    /// deceptive origin would either truncate mid-string or crowd out the
    /// sentence that carries the meaning. The user already knows which document
    /// they opened; naming its host buys nothing here.
    static let remoteStaleDetail = String(
        localized:
            "The remote file has grown past the \(DocumentURLValidator.maxFileSizeMegabytes) MB limit, so it stopped refreshing. Showing the last version that fit.",
        comment:
            "Document banner when a remote snapshot stops refreshing because the remote file is over the cap; the placeholder is the cap in whole megabytes"
    )

    static let remoteRefreshFailedDetail = String(
        localized: "Couldn't refresh the remote file. Showing the last copy that arrived.",
        comment:
            "Document banner when a remote snapshot refresh fails and the last cached copy remains visible"
    )

    static func kicker(for kind: Kind) -> String {
        switch kind {
        case .localFileGrew:
            String(
                localized: "file outgrew the limit",
                comment: "Document banner kicker when a local file grows past the size cap")
        case .remoteStoppedRefreshing, .remoteRefreshFailed:
            String(
                localized: "showing a stale copy",
                comment:
                    "Document banner kicker when a remote snapshot could not be refreshed"
            )
        }
    }

    static func detail(for kind: Kind) -> String {
        switch kind {
        case .localFileGrew: detail
        case .remoteStoppedRefreshing: remoteStaleDetail
        case .remoteRefreshFailed: remoteRefreshFailedDetail
        }
    }

    /// Spoken when the banner appears and whenever VoiceOver lands on it.
    /// Built from two single-argument strings rather than one two-argument
    /// string so neither catalog entry needs positional specifiers.
    ///
    /// "too large to render", not "can no longer be reloaded": the file reads
    /// back perfectly well, and the first thing spoken should not claim
    /// otherwise — the reader whose file just crossed the cap would go looking
    /// for a permissions or disk problem that isn't there.
    static func accessibilityLabel(
        fileName: String,
        kind: Kind = .localFileGrew
    ) -> String {
        let lead: String
        switch kind {
        case .localFileGrew:
            lead = String(
                localized: "\(fileName) is now too large to render.",
                comment: "Accessibility lead-in for the document oversize banner; the placeholder is the file name"
            )
        case .remoteStoppedRefreshing:
            // "stopped refreshing", not "is too large": the copy on screen
            // rendered fine and still does. What failed is the refresh, and a
            // reader told the document is too large would go looking for a
            // rendering problem that is not there.
            lead = String(
                localized: "\(fileName) stopped refreshing.",
                comment:
                    "Accessibility lead-in for the banner shown when a remote snapshot can no longer be refreshed; the placeholder is the file name"
            )
        case .remoteRefreshFailed:
            lead = String(
                localized: "\(fileName) couldn't be refreshed.",
                comment:
                    "Accessibility lead-in for the banner shown when a remote snapshot refresh fails; the placeholder is the file name"
            )
        }
        return "\(lead) \(detail(for: kind))"
    }
}
