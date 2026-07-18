import AppKit
import DesignSystem
import SwiftUI

// MARK: - Metadata

/// Bundle-derived facts shown in the About window. Version and revision come
/// from whatever the running bundle carries — dev builds use a `.dev` bundle id
/// and a tag-derived version, so nothing here is hardcoded. The `infoValue`
/// closure is injected so the formatting can be unit-tested against missing /
/// empty / malformed values without a real bundle.
struct AboutInfo {
    /// Marketing version with build, e.g. `0.3.0 (128)`; falls back to the
    /// bare version, the bare build, or "Development" for a non-bundle run.
    let version: String
    /// Short git revision the build was stamped from, or `nil` when the bundle
    /// carries no (or an empty) `AwesoMuxSourceRevision` — e.g. `swift run`.
    let sourceRevision: String?

    init(infoValue: (String) -> Any?) {
        version = Self.formatVersion(
            short: infoValue("CFBundleShortVersionString") as? String,
            build: infoValue("CFBundleVersion") as? String
        )
        sourceRevision = Self.normalized(infoValue("AwesoMuxSourceRevision") as? String)
    }

    /// Trim and treat a blank string as absent — every info value goes through
    /// this so a whitespace-only key never renders literally.
    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static func formatVersion(short: String?, build: String?) -> String {
        let version = normalized(short)
        let build = normalized(build)
        switch (version, build) {
        case let (.some(version), .some(build)): return "\(version) (\(build))"
        case let (.some(version), .none): return version
        case let (.none, .some(build)): return build
        case (.none, .none):
            return String(
                localized: "Development",
                comment: "About window version value shown for a non-release local build")
        }
    }
}

extension AboutInfo {
    init(bundle: Bundle = .main) {
        self.init(infoValue: { bundle.object(forInfoDictionaryKey: $0) })
    }
}

// MARK: - Credits

/// A bundled third-party component and its shipped license file. The file paths
/// mirror `script/build_and_run.sh`'s `required_license_files`; when a license
/// URL fails to resolve the "View license" button is hidden entirely. The
/// credits test asserts each entry exists in the source `Resources/Licenses`
/// tree AND is listed in `required_license_files`, so a manifest that drifts
/// from the shipped/copied set fails CI rather than silently dropping a license.
struct AboutCredit: Identifiable {
    var id: String { name }
    let name: String
    let attribution: String
    /// Resource name (without extension) under `Licenses/<subdirectory>`.
    let resource: String
    /// File extension, or `nil` for extension-less files like `LICENSE`.
    let ext: String?
    /// Subdirectory beneath the bundle's `Licenses/` folder.
    let subdirectory: String
    /// Optional secondary NOTICE file (Apache-2.0 components).
    let notice: (resource: String, ext: String)?

    init(
        name: String,
        attribution: String,
        resource: String,
        ext: String?,
        subdirectory: String,
        notice: (resource: String, ext: String)? = nil
    ) {
        self.name = name
        self.attribution = attribution
        self.resource = resource
        self.ext = ext
        self.subdirectory = subdirectory
        self.notice = notice
    }

    static let all: [AboutCredit] = [
        AboutCredit(
            name: "libghostty",
            attribution: "Ghostty terminal core — MIT",
            resource: "LICENSE", ext: nil, subdirectory: "Ghostty"),
        AboutCredit(
            name: "zmx",
            attribution: "Session daemon — MIT",
            resource: "LICENSE", ext: nil, subdirectory: "zmx"),
        AboutCredit(
            name: "swift-markdown",
            attribution: "Markdown rendering — Apache-2.0",
            resource: "LICENSE", ext: "txt", subdirectory: "swift-markdown",
            notice: (resource: "NOTICE", ext: "txt")),
        AboutCredit(
            name: "swift-cmark",
            attribution: "CommonMark parser — BSD-2-Clause",
            resource: "COPYING", ext: nil, subdirectory: "swift-cmark"),
        AboutCredit(
            name: "swift-toml",
            attribution: "TOML config parsing — MIT",
            resource: "LICENSE", ext: "md", subdirectory: "swift-toml"),
        AboutCredit(
            name: "Geist Sans",
            attribution: "Interface font — SIL OFL 1.1",
            resource: "OFL", ext: "txt", subdirectory: "Geist"),
        AboutCredit(
            name: "Hack Nerd Font Mono",
            attribution: "Terminal font — MIT",
            resource: "LICENSE", ext: "md", subdirectory: "HackNerdFontMono"),
    ]

    func licenseURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resource, withExtension: ext, subdirectory: "Licenses/\(subdirectory)")
    }

    func noticeURL(in bundle: Bundle = .main) -> URL? {
        guard let notice else { return nil }
        return bundle.url(
            forResource: notice.resource, withExtension: notice.ext,
            subdirectory: "Licenses/\(subdirectory)")
    }
}

// MARK: - View

struct AboutWindowView: View {
    private static let repositoryURL = URL(string: "https://github.com/Interactive-Buffoonery/awesomux")!
    private static let licenseURL = URL(
        string: "https://github.com/Interactive-Buffoonery/awesomux/blob/main/LICENSE")!

    private let info = AboutInfo()

    var body: some View {
        VStack(spacing: AwSpacing.sectionGap) {
            identity
            metadata
            credits
            links
        }
        .padding(AwSpacing.panelPadding)
        .frame(width: 360)
        .background(Color.aw.surface.window)
        .background(
            // reassertsOnBecomeKey mirrors SettingsShell: AppKit can restore
            // standard-button visibility on become-key (e.g. Cmd-Tab away and
            // back), so the close-only chrome must be re-applied then.
            WindowChromeConfigurator(
                windowRole: .about,
                reassertsOnBecomeKey: true,
                standardWindowButtonVisibility: .closeOnly,
                centersOnAttach: true
            )
            .allowsHitTesting(false))
    }

    private var identity: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(verbatim: "awesoMux")
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)

            Text(
                String(
                    localized: "A native terminal for agents",
                    comment: "About window tagline shown under the app name")
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text2)
        }
    }

    private var metadata: some View {
        VStack(spacing: 6) {
            metadataRow(
                label: String(localized: "Version", comment: "About window field label for the app version"),
                value: info.version)
            if let revision = info.sourceRevision {
                metadataRow(
                    label: String(localized: "Build", comment: "About window field label for the source revision hash"),
                    value: revision)
            }
            metadataRow(
                label: String(localized: "Terminal backend", comment: "About window field label for the terminal engine"),
                value: "libghostty")
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(value)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .textSelection(.enabled)
                // The value is the load-bearing part; let it win space over the
                // label so a long localized label can't truncate the version.
                .layoutPriority(1)
        }
        // One VoiceOver stop per row: "Version, 0.3.0 (128)" not two fragments.
        .accessibilityElement(children: .combine)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Open source", comment: "About window section heading for bundled third-party licenses"))
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text3)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AboutCredit.all) { credit in
                        creditRow(credit)
                    }
                }
                .padding(.trailing, 4)
                // Fill the proposed width — unlike the metadata rows (whose
                // Spacers expand them), nothing here is naturally full-width,
                // so without this the card hugs its content and renders
                // narrower than the info rows above it.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 168)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.elevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .stroke(Color.aw.border, lineWidth: 0.5)
            }
        }
    }

    private func creditRow(_ credit: AboutCredit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(credit.name)
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text)
            Text(credit.attribution)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
            // Short visible labels keep the two-button row inside the fixed
            // window width under longer localizations; the accessibility labels
            // carry the full "View license for <component>" phrasing (which also
            // keeps the visible word as a substring for Voice Control, WCAG 2.5.3).
            HStack(spacing: 12) {
                if let licenseURL = credit.licenseURL() {
                    Button(String(localized: "License", comment: "Button opening a bundled third-party license file")) {
                        openReadable(licenseURL)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(
                        String(
                            localized: "View license for \(credit.name)",
                            comment: "Accessibility label for the button opening a component's license. Argument is the component name."))
                }
                if let noticeURL = credit.noticeURL() {
                    Button(String(localized: "Notice", comment: "Button opening a bundled third-party NOTICE file")) {
                        openReadable(noticeURL)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(
                        String(
                            localized: "View notice for \(credit.name)",
                            comment: "Accessibility label for the button opening a component's NOTICE. Argument is the component name."))
                }
            }
        }
    }

    /// Bundled license files are extension-less (`LICENSE`, `COPYING`) or `.md`,
    /// which often have no default handler — `NSWorkspace.open` then silently
    /// returns false. Fall back to revealing the file in Finder so the button
    /// always does something observable.
    private func openReadable(_ url: URL) {
        guard !NSWorkspace.shared.open(url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var links: some View {
        HStack(spacing: 18) {
            Link(String(localized: "GitHub", comment: "About window link to the project repository"), destination: Self.repositoryURL)
            Link(String(localized: "License", comment: "About window link to the project's own MIT license"), destination: Self.licenseURL)
            Spacer()
            Text(verbatim: "MIT")
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
        }
        .buttonStyle(.link)
    }
}
