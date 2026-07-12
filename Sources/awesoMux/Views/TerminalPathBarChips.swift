import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Plain visuals only — no accessibility identity, no context menu. Mirrors
/// `PathBarPRChip`/`PathBarCIChip`: the wrapping `Button` at this chip's one
/// call site (the branch chip in `localContent`) owns accessibility, `.help`,
/// and the Copy Branch context menu / a11y action instead.
struct PathBarChip: View {
    private static let maxLabelWidth: CGFloat = 240

    let icon: String
    let label: String
    let tone: Color
    /// Optional short suffix (e.g. `↑1 ↓2`) rendered fainter, after the label. It
    /// is intentionally NOT part of the label's width measurement: only the label
    /// (a branch name) caps + truncates; the hint is always short and stays whole.
    var hint: String?
    @State private var measuredLabelWidth: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            Text(label)
                .awFont(AwFont.Mono.pill)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: measuredLabelWidth.map(cappedLabelWidth), alignment: .leading)
                .background {
                    Text(label)
                        .awFont(AwFont.Mono.pill)
                        .fixedSize()
                        .hidden()
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: PathBarChipLabelWidthPreferenceKey.self,
                                        value: proxy.size.width
                                    )
                            }
                        }
                }

            if let hint {
                Text(hint)
                    .awFont(AwFont.Mono.pill)
                    .fixedSize()
                    .foregroundStyle(tone.opacity(0.65))
            }
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: AwRadius.pill))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.pill)
                .stroke(tone.opacity(0.38), lineWidth: 0.5)
        }
        .onPreferenceChange(PathBarChipLabelWidthPreferenceKey.self) { width in
            measuredLabelWidth = width
        }
    }

    private func cappedLabelWidth(_ width: CGFloat) -> CGFloat {
        min(width, Self.maxLabelWidth)
    }
}

struct PathBarDirtyChip: View {
    let count: Int

    // Cap the display so a pathological working copy (thousands of untracked
    // files) can't blow out the chrome width.
    private var label: String { count > 999 ? "+999+" : "+\(count)" }
    private var spoken: String { LocalizedPluralStrings.pathbarUncommittedChanges(count: count) }

    var body: some View {
        Text(label)
            .awFont(AwFont.Mono.pill)
            .foregroundStyle(Color.aw.yellow)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.aw.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: AwRadius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.pill)
                    .stroke(Color.aw.yellow.opacity(0.40), lineWidth: 0.5)
            }
            .help(spoken)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken)
    }
}

struct PathBarPRChip: View {
    let pullRequest: PullRequestInfo
    let canCheckout: Bool
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onCheckout: () -> Void

    private var tone: Color {
        switch pullRequest.state {
        case .open: Color.aw.green
        case .draft: Color.aw.mauve
        case .inReview: Color.aw.sky
        }
    }

    private var label: String {
        switch pullRequest.state {
        case .open: "PR #\(pullRequest.number)"
        case .draft: "PR #\(pullRequest.number) · draft"
        case .inReview: "PR #\(pullRequest.number) · review"
        }
    }

    private var stateDescription: String {
        switch pullRequest.state {
        case .open: "open"
        case .draft: "draft"
        case .inReview: "in review"
        }
    }

    var body: some View {
        Button {
            // SwiftUI's Button action carries no modifier state, so read the live
            // flags. ⌘ copies the URL; ⌥ checks the PR out into the active shell
            // pane (falling back to copy when that pane isn't a shell); a plain
            // click opens the PR in the browser.
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                onCopyURL()
            } else if flags.contains(.option) {
                canCheckout ? onCheckout() : onCopyURL()
            } else {
                onOpen()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)

                Text(label)
                    .awFont(AwFont.Mono.pill)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: AwRadius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.pill)
                    .stroke(tone.opacity(0.42), lineWidth: 0.5)
            }
            // Keep the visible pill compact but give the button a ≥24pt tappable
            // height (the visible chip stays centered within it).
            .frame(minHeight: 24)
            .contentShape(RoundedRectangle(cornerRadius: AwRadius.pill))
        }
        .buttonStyle(.plain)
        .help("Pull request #\(pullRequest.number) (\(stateDescription)) — click to open"
            + ", ⌘-click to copy URL"
            + (canCheckout ? ", ⌥-click to insert the checkout command" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pull request \(pullRequest.number), \(stateDescription)")
        .accessibilityHint("Opens the pull request in your browser.")
        // Both secondary actions live in one builder so neither shadows the other
        // in the VoiceOver rotor; the plain activation (open) is the default tap.
        .accessibilityActions {
            Button("Copy Pull Request URL") { onCopyURL() }
            if canCheckout {
                // "Insert", not "Check Out": this stages the command at the prompt
                // without a trailing newline; the user presses Return to run it.
                Button("Insert Checkout Command") { onCheckout() }
            }
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            Button {
                onCopyURL()
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            if canCheckout {
                Button {
                    onCheckout()
                } label: {
                    Label("Insert Checkout Command", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct PathBarCIChip: View {
    let ciStatus: CIStatusInfo
    let canRunInPane: Bool
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onRunInPane: () -> Void

    private var tone: Color {
        switch ciStatus.state {
        case .failing: Color.aw.red
        case .running: Color.aw.sky
        }
    }

    // Text-only (no SF Symbol) — the glyph IS the label, matching the dirty
    // chip's `+N`. `✕` (U+2715) and `…` (U+2026) read at pill size.
    private var label: String {
        switch ciStatus.state {
        case .failing: "CI ✕"
        case .running: "CI …"
        }
    }

    private var stateDescription: String {
        switch ciStatus.state {
        case .failing: "failing"
        case .running: "running"
        }
    }

    /// The ⌥-action's name. "Insert", not "Watch"/"View": like the PR chip's
    /// "Insert Checkout Command", this stages the command at the prompt without a
    /// trailing newline — the user presses Return to run it. The verb still differs
    /// by state: a running run is worth watching live; a failed one, its logs.
    private var paneActionName: String {
        switch ciStatus.state {
        case .failing: "Insert Failure-Log Command"
        case .running: "Insert Watch Command"
        }
    }

    private var paneActionHelp: String {
        switch ciStatus.state {
        case .failing: "insert the failure-log command"
        case .running: "insert the watch command"
        }
    }

    private var paneActionIcon: String {
        switch ciStatus.state {
        case .failing: "doc.text.magnifyingglass"
        case .running: "eye"
        }
    }

    /// ` (Swift CI)` when gh named the workflow, else empty — disambiguates the
    /// opaque `CI ✕` glyph in a repo with several workflows, and clarifies that the
    /// chip is *this workflow's* latest run, not aggregate PR-CI.
    private var workflowSuffix: String {
        ciStatus.workflowName.map { " (\($0))" } ?? ""
    }

    var body: some View {
        Button {
            // SwiftUI's Button action carries no modifier state, so read the live
            // flags. ⌘ copies the run URL; ⌥ runs the state-appropriate command in
            // the active shell pane (falling back to copy when it isn't a shell); a
            // plain click opens the run in the browser.
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                onCopyURL()
            } else if flags.contains(.option) {
                canRunInPane ? onRunInPane() : onCopyURL()
            } else {
                onOpen()
            }
        } label: {
            Text(label)
                .awFont(AwFont.Mono.pill)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(tone)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: AwRadius.pill))
                .overlay {
                    RoundedRectangle(cornerRadius: AwRadius.pill)
                        .stroke(tone.opacity(0.42), lineWidth: 0.5)
                }
                // Keep the visible pill compact but give the button a ≥24pt tappable
                // height (the visible chip stays centered within it).
                .frame(minHeight: 24)
                .contentShape(RoundedRectangle(cornerRadius: AwRadius.pill))
        }
        .buttonStyle(.plain)
        .help("CI \(stateDescription)\(workflowSuffix) — click to open"
            + ", ⌘-click to copy URL"
            + (canRunInPane ? ", ⌥-click to \(paneActionHelp)" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Continuous integration \(stateDescription)"
            + (ciStatus.workflowName.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the run in your browser.")
        // Both secondary actions live in one builder so neither shadows the other
        // in the VoiceOver rotor; the plain activation (open) is the default tap.
        .accessibilityActions {
            Button("Copy Run URL") { onCopyURL() }
            if canRunInPane {
                Button(paneActionName) { onRunInPane() }
            }
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            Button {
                onCopyURL()
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            if canRunInPane {
                Button {
                    onRunInPane()
                } label: {
                    Label(paneActionName, systemImage: paneActionIcon)
                }
            }
        }
    }
}

private struct PathBarChipLabelWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
