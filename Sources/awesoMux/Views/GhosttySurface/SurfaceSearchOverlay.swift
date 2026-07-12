import AwesoMuxCore
import AppKit
import DesignSystem
import SwiftUI

struct SurfaceSearchOverlay: View {
    let runtime: GhosttyRuntime
    let paneID: TerminalPane.ID

    @State private var surfaceView: GhosttySurfaceNSView?

    var body: some View {
        Group {
            if let surfaceView {
                SurfaceSearchBar(
                    surfaceView: surfaceView,
                    searchState: surfaceView.searchState
                )
            }
        }
        .task(id: runtime.surfaceCacheRevision) {
            surfaceView = runtime.cachedSurfaceView(for: paneID)
        }
        .onAppear {
            surfaceView = runtime.cachedSurfaceView(for: paneID)
        }
    }
}

private struct SurfaceSearchBar: View {
    let surfaceView: GhosttySurfaceNSView
    @Bindable var searchState: SurfaceSearchState

    @State private var matchAnnouncementWorkItem: DispatchWorkItem?
    @Environment(\.awAccent) private var accentResolver
    @FocusState private var isSearchFieldFocused: Bool

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }
    private var accentSoftColor: Color { Color.aw.accentSoft(accentResolver.accent) }

    var body: some View {
        Group {
            if searchState.isPresented {
                bar
            }
        }
        .sheet(
            isPresented: Binding(
                get: { searchState.scrollbackDumpText != nil },
                set: { isPresented in
                    if !isPresented {
                        surfaceView.dismissScrollbackDump()
                    }
                }
            )
        ) {
            ScrollbackDumpSheet(
                text: searchState.scrollbackDumpText ?? "",
                onDismiss: { surfaceView.dismissScrollbackDump() }
            )
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            searchField

            Text(searchState.matchCountText)
                .awFont(AwFont.Mono.kbd)
                .monospacedDigit()
                .foregroundStyle(Color.aw.text3)
                .accessibilityLabel(searchState.spokenSummary)

            Divider()
                .frame(height: 18)

            navButton(
                systemName: "chevron.up",
                help: "Previous match",
                action: { surfaceView.navigateSearch(.previous) }
            )
            navButton(
                systemName: "chevron.down",
                help: "Next match",
                action: { surfaceView.navigateSearch(.next) }
            )
            navButton(
                systemName: "xmark",
                help: "Close find",
                action: { surfaceView.endSearch() }
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.aw.surface.chrome.opacity(0.88))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .awShadow(.findBar)
        .padding(.top, 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: searchState.focusRequestSerial) { _, _ in
            isSearchFieldFocused = true
        }
        .onChange(of: searchState.total) { _, _ in
            scheduleSearchSummaryAnnouncement()
        }
        .onDisappear {
            matchAnnouncementWorkItem?.cancel()
            matchAnnouncementWorkItem = nil
        }
    }

    private var searchField: some View {
        TextField("Search", text: $searchState.needle)
            .textFieldStyle(.plain)
            .font(AwFont.mono(.terminal))
            .foregroundStyle(Color.aw.text)
            .frame(width: 200)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accentColor, lineWidth: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accentSoftColor, lineWidth: isSearchFieldFocused ? 2 : 0)
            }
            .focused($isSearchFieldFocused)
            .focusEffectDisabled()
            .onChange(of: searchState.needle) { _, newValue in
                surfaceView.updateSearchNeedle(newValue)
            }
            .onKeyPress(.return, phases: .down) { keyPress in
                surfaceView.navigateSearch(keyPress.modifiers.contains(.shift) ? .previous : .next)
                return .handled
            }
            .onKeyPress(.escape) {
                if isSearchFieldFocused && !searchState.needle.isEmpty {
                    isSearchFieldFocused = false
                    surfaceView.window?.makeFirstResponder(surfaceView)
                    return .handled
                }
                surfaceView.endSearch()
                return .handled
            }
            .onKeyPress(.upArrow) {
                surfaceView.navigateSearch(.previous)
                return .handled
            }
            .onKeyPress(.downArrow) {
                surfaceView.navigateSearch(.next)
                return .handled
            }
            .accessibilityLabel("Find")
            .accessibilityValue(
                searchState.needle.isEmpty ? "No search" : searchState.spokenSummary
            )
    }

    private func scheduleSearchSummaryAnnouncement() {
        matchAnnouncementWorkItem?.cancel()
        matchAnnouncementWorkItem = nil

        guard searchState.isPresented, !searchState.needle.isEmpty else {
            return
        }

        let workItem = DispatchWorkItem { [weak surfaceView, weak searchState] in
            guard let surfaceView,
                  let searchState,
                  searchState.isPresented,
                  !searchState.needle.isEmpty,
                  let window = surfaceView.window else {
                return
            }
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: searchState.spokenSummary,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
        matchAnnouncementWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func navButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.aw.text3)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
