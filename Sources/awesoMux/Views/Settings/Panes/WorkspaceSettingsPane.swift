import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore

    @State private var draftDefaultGroup = ""
    @FocusState private var defaultGroupFocused: Bool
    @State private var installedIDEs: [InstalledIDE] = []
    @State private var draggingBundleID: String?

    private var defaultGroup: String {
        appSettingsStore.workspaces.value.defaultGroup
    }

    private var openInIDEEnabled: Bool {
        appSettingsStore.workspaces.value.openInIDEEnabled
    }

    private var idePriority: [String] {
        appSettingsStore.workspaces.value.defaultIDEPriority
    }

    private var orderedInstalledIDEs: [InstalledIDE] {
        IDEChoice.ordered(installed: installedIDEs, priority: idePriority)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: "Defaults",
                subtitle: "What awesoMux uses when you create a workspace without picking a group."
            ) {
                SettingsField(
                    label: "Default group",
                    hint: "Whitespace, control characters, and bidi overrides are normalized on commit.",
                    isFirst: true,
                    // Without forwarding, VoiceOver names this field by its
                    // placeholder ("awesoMux"), not "Default group".
                    forwardsAccessibilityToControl: true
                ) {
                    TextField("awesoMux", text: $draftDefaultGroup)
                        .textFieldStyle(.roundedBorder)
                        .focused($defaultGroupFocused)
                        .onSubmit { commitDefaultGroup() }
                        .onChange(of: defaultGroupFocused) { _, focused in
                            if !focused { commitDefaultGroup() }
                        }
                        .frame(maxWidth: 280)
                }

                SettingsField(
                    label: "Output marks needs attention",
                    hint: "Inactive sessions that emit output get a needs-attention indicator in the sidebar.",
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Output marks needs attention", isOn: appSettingsStore.workspaces.binding(\.outputMarksNeedsAttention))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: "Confirm before closing workspaces with activity",
                    hint:
                        "Ask before ⌘⇧W, the sidebar close button, or ⌘W on a workspace's last pane closes a workspace with active agent or terminal activity. Skipped when nothing's at risk. App quit (⌘Q) has its own prompt; ⌘W on any other pane uses the toggle below.",
                    forwardsAccessibilityToControl: true,
                    // Deliberate: the toggle's own hint below spells the
                    // shortcuts out for speech ("Command-Shift-W", not "⌘⇧W").
                    // Forwarding the field's glyph-heavy hint would replace it.
                    forwardsHintToControl: false
                ) {
                    Toggle(
                        "Confirm before closing workspaces with activity",
                        isOn: appSettingsStore.workspaces.binding(\.confirmCloseWithRunningAgent)
                    )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint(
                        "Asks before Command-Shift-W, the sidebar close button, or Command-W on a workspace's last pane closes a workspace whose agent or shell is active. Skipped when nothing is at risk. Command-Q (app quit) has its own prompt. Command-W on any other pane uses the pane-confirmation toggle below."
                        )
                }

                SettingsField(
                    label: "Confirm before closing panes with activity",
                    hint:
                        "Ask before ⌘W closes a pane with running activity. On a workspace's last pane, this also gates the workspace-close prompt above.",
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    Toggle(
                        "Confirm before closing panes with activity",
                        isOn: appSettingsStore.workspaces.binding(\.confirmDestructivePaneActionWithRunningAgent)
                    )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint(
                        "Asks before Command-W closes a pane whose agent or shell is active. Skipped when nothing is at risk. Command-W on a workspace's last pane closes the workspace; this toggle also gates that workspace-close prompt, in addition to the toggle above."
                        )
                }
            }

            openInIDESection
        }
        .task { await refreshInstalledIDEs() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refreshInstalledIDEs() }
        }
        .onAppear {
            let normalized = WorkspaceConfig.normalizedDefaultGroup(defaultGroup)
            if normalized != defaultGroup {
                appSettingsStore.workspaces.update { workspaces in
                    workspaces.defaultGroup = normalized
                }
            }
            draftDefaultGroup = normalized
        }
        .onChange(of: defaultGroup) { _, newValue in
            if !defaultGroupFocused {
                draftDefaultGroup = newValue
            }
        }
    }

    private func commitDefaultGroup() {
        let committedGroup = WorkspaceConfig.normalizedDefaultGroup(draftDefaultGroup)
        appSettingsStore.workspaces.update { workspaces in
            workspaces.defaultGroup = committedGroup
        }
        draftDefaultGroup = committedGroup
    }

    @ViewBuilder
    private var openInIDESection: some View {
        SettingsSection(
            index: 2,
            title: "Open in IDE",
            subtitle: "Show editor choices in the path bar and set which editor opens by default. The top installed editor is used automatically."
        ) {
            SettingsField(
                label: "Show Open in IDE",
                hint: "Adds editor choices in the path bar and the Open in IDE command.",
                isFirst: true,
                forwardsAccessibilityToControl: true
            ) {
                Toggle(
                    "Show Open in IDE",
                    isOn: appSettingsStore.workspaces.binding(\.openInIDEEnabled)
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if openInIDEEnabled {
                if orderedInstalledIDEs.isEmpty {
                    noEditorsInstalledWarning
                }

                SettingsField(
                    label: "Editor priority",
                    hint: "Drag to reorder. The top installed editor opens by default."
                ) {
                    idePriorityControl
                }
            }
        }
    }

    // Symbol + color so the warning doesn't rely on color alone: the feature is
    // on but nothing was found to open with, so the titlebar control disables
    // itself until an editor is installed.
    private var noEditorsInstalledWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text("No supported editors are installed. Install one, or add it below, for the Open control to work.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(Color.aw.text2)
        .frame(maxWidth: Self.listMaxWidth, alignment: .leading)
    }

    private static let listMaxWidth: CGFloat = 360
    private static let rowHeight: CGFloat = 34

    @ViewBuilder
    private var idePriorityControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if orderedInstalledIDEs.isEmpty {
                Text("No editors added yet")
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text3)
                    .frame(maxWidth: Self.listMaxWidth, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedInstalledIDEs, id: \.bundleIdentifier) { ide in
                        draggableRow(ide)
                    }
                }
                .frame(maxWidth: Self.listMaxWidth, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .fill(Color.aw.surface.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: AwRadius.button)
                                .stroke(Color.aw.border, lineWidth: 0.5)
                        )
                )
            }

            Button {
                addEditor()
            } label: {
                Label("Add Editor…", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func draggableRow(_ ide: InstalledIDE) -> some View {
        let index = orderedInstalledIDEs.firstIndex { $0.bundleIdentifier == ide.bundleIdentifier } ?? 0
        let isDefault = index == 0

        VStack(spacing: 0) {
            if index > 0 {
                Rectangle()
                    .fill(Color.aw.border)
                    .frame(height: 0.5)
            }
            ideRow(ide, isDefault: isDefault)
        }
        .opacity(draggingBundleID == ide.bundleIdentifier ? 0.4 : 1)
        .onDrag {
            draggingBundleID = ide.bundleIdentifier
            return NSItemProvider(object: ide.bundleIdentifier as NSString)
        } preview: {
            ideRow(ide, isDefault: isDefault)
                .frame(width: Self.listMaxWidth)
                .background(
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .fill(Color.aw.surface.elevated)
                )
        }
        .onDrop(
            of: [.text],
            delegate: IDEReorderDropDelegate(
                targetBundleID: ide.bundleIdentifier,
                draggingBundleID: $draggingBundleID,
                order: orderedInstalledIDEs.map(\.bundleIdentifier),
                commit: commitOrder
            )
        )
    }

    private func ideRow(_ ide: InstalledIDE, isDefault: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(Color.aw.text3)
                .accessibilityHidden(true)

            Image(nsImage: NSWorkspace.shared.icon(forFile: ide.applicationURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            Text(ide.displayName)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isDefault {
                Text("Default")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.aw.surface.active, in: Capsule())
                    .accessibilityLabel("Default editor")
            }

            Button {
                removeEditor(ide)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.aw.text3)
            }
            .buttonStyle(.plain)
            .help("Remove editor")
            .accessibilityLabel("Remove \(ide.displayName)")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDefault ? "\(ide.displayName), default editor" : ide.displayName)
    }

    private func commitOrder(_ order: [String]) {
        appSettingsStore.workspaces.update { $0.defaultIDEPriority = order }
    }

    private func removeEditor(_ ide: InstalledIDE) {
        var order = orderedInstalledIDEs.map(\.bundleIdentifier)
        order.removeAll { $0 == ide.bundleIdentifier }
        commitOrder(order)
        // A known editor stays discoverable and reappears in allowlist order;
        // only a user-added custom app leaves the list entirely, so prune the
        // stale local entry now instead of waiting for the next refresh.
        let isKnown = InstalledIDEDiscovery.knownIDEs.contains { $0.bundleIdentifier == ide.bundleIdentifier }
        if !isKnown {
            installedIDEs.removeAll { $0.bundleIdentifier == ide.bundleIdentifier }
        }
    }

    private func addEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Add", comment: "Confirm button for the Add Editor file picker.")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return
        }
        // Append to the end of the explicit order, then let discovery pick the
        // app up on the next refresh. Dedupe keeps a re-add from stacking.
        var order = orderedInstalledIDEs.map(\.bundleIdentifier)
        if !order.contains(bundleID) {
            order.append(bundleID)
        }
        appSettingsStore.workspaces.update { $0.defaultIDEPriority = order }
        Task { await refreshInstalledIDEs() }
    }

    @MainActor
    private func refreshInstalledIDEs() async {
        let extraBundleIdentifiers = idePriority
        installedIDEs = await Task.detached(priority: .utility) {
            InstalledIDEDiscovery.installed(
                extraBundleIdentifiers: extraBundleIdentifiers,
                resolveApplicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                displayName: InstalledIDEDiscovery.bundleDisplayName
            )
        }.value
    }
}

/// Reorders the priority list live as a dragged row hovers another. Moving the
/// dragged id in front of (or behind, past the midpoint) the hovered target and
/// committing on each `dropEntered` makes the whole row slide during the drag —
/// the plain `List.onMove` insertion line doesn't. The commit persists the full
/// ordered list so the top stays unambiguous.
private struct IDEReorderDropDelegate: DropDelegate {
    let targetBundleID: String
    @Binding var draggingBundleID: String?
    let order: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingBundleID,
              dragging != targetBundleID,
              let fromIndex = order.firstIndex(of: dragging),
              let toIndex = order.firstIndex(of: targetBundleID) else {
            return
        }
        var reordered = order
        reordered.remove(at: fromIndex)
        let insertionIndex = reordered.firstIndex(of: targetBundleID)
            .map { fromIndex < toIndex ? $0 + 1 : $0 } ?? reordered.count
        reordered.insert(dragging, at: insertionIndex)
        commit(reordered)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingBundleID = nil
        return true
    }
}
