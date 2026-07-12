import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct AdvancedSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: "Configuration",
                subtitle: "TOML at \(appSettingsStore.configURL.path)."
            ) {
                SettingsField(
                    label: "Path",
                    hint: "Edit this file in any text editor; awesoMux reloads on save.",
                    isFirst: true
                ) {
                    Text(appSettingsStore.configURL.path)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text2)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                SettingsField(label: "Schema version") {
                    Text("v\(appSettingsStore.advanced.value.configSchemaVersion)")
                        .awFont(AwFont.Mono.body)
                        .foregroundStyle(Color.aw.text2)
                }

                SettingsField(
                    label: "Actions",
                    hint: "Reveal opens Finder. Open uses your default editor. Reload re-reads the file from disk."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") { revealInFinder() }
                            Button("Open in Editor") { openInEditor() }
                            Button("Reload from Disk") { reloadFromDisk() }
                        }

                        if appSettingsStore.isDiskConfigInvalid {
                            Button(role: .destructive) {
                                replaceInvalidFile()
                            } label: {
                                Text("Replace Invalid File with Current Settings")
                            }
                            .accessibilityHint("Overwrites the on-disk config file with the current settings. Cannot be undone.")
                        }
                    }
                }

                if let errorText {
                    SettingsField(label: "Latest error") {
                        Text(errorText)
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.text)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: AwRadius.button)
                                    .fill(Color.aw.surface.elevated)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: AwRadius.button)
                                    .stroke(Color.aw.border, lineWidth: 0.5)
                            }
                    }
                }
            }

            SettingsSection(index: 2, title: "About") {
                SettingsField(label: "Version", isFirst: true) {
                    Text(Bundle.main.appVersionDisplay)
                        .awFont(AwFont.Mono.body)
                        .foregroundStyle(Color.aw.text2)
                        .textSelection(.enabled)
                }

                SettingsField(label: "Bundle") {
                    Text(Bundle.main.bundleIdentifier ?? "Unknown")
                        .awFont(AwFont.Mono.body)
                        .foregroundStyle(Color.aw.text2)
                        .textSelection(.enabled)
                }

                SettingsField(label: "License") {
                    Text("MIT")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text2)
                }

                SettingsField(label: "Terminal backend") {
                    Text("libghostty")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text2)
                }

                SettingsField(label: String(
                    localized: "Bundled UI font",
                    comment: "About settings field label for the bundled interface font attribution"
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(
                            localized: "Geist Sans — Copyright 2024 The Geist Project Authors. SIL Open Font License 1.1.",
                            comment: "About settings attribution for the bundled Geist Sans interface font"
                        ))
                            .awFont(AwFont.UI.label)
                            .foregroundStyle(Color.aw.text2)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(String(
                            localized: "View license",
                            comment: "Button that opens the bundled Geist Sans license"
                        )) {
                            openGeistLicense()
                        }
                        .buttonStyle(.link)
                        .disabled(geistLicenseURL == nil)
                    }
                }
            }
        }
    }

    private var errorText: String? {
        appSettingsStore.latestError?.displayText
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([appSettingsStore.configURL])
    }

    private func openInEditor() {
        NSWorkspace.shared.open(appSettingsStore.configURL)
    }

    private func reloadFromDisk() {
        appSettingsStore.reloadFromDisk()
    }

    private var geistLicenseURL: URL? {
        Bundle.main.url(
            forResource: "OFL",
            withExtension: "txt",
            subdirectory: "Licenses/Geist"
        )
    }

    private func openGeistLicense() {
        guard let geistLicenseURL else { return }
        NSWorkspace.shared.open(geistLicenseURL)
    }

    private func replaceInvalidFile() {
        appSettingsStore.replaceInvalidFileWithCurrentConfig()
    }
}

private extension Bundle {
    var appVersionDisplay: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(v), .some(b)): return "\(v) (\(b))"
        case let (.some(v), .none): return v
        case let (.none, .some(b)): return b
        case (.none, .none): return "Development"
        }
    }
}
