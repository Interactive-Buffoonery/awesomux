import AwesoMuxConfig
import DesignSystem
import SwiftUI

/// Two-pane settings layout: a fixed-width sidebar over the chrome sidebar
/// surface tone, and a scrollable detail column with the design-handoff
/// content insets.
///
/// Replaces the stock `NavigationSplitView` look. Sidebar selection is
/// driven by a `Selection` enum supplied by the caller so the shell is
/// reusable for any settings shape we land on (the full Settings scene
/// today, potentially a chrome-overlay route later).
///
/// The shell renders its title bar inside the full-size SwiftUI content view,
/// matching the main window's chrome geometry while `WindowChromeConfigurator`
/// keeps the native title bar transparent and stable across focus changes.
enum SettingsTitlebarMetrics {
    static let height = AwSpacing.titlebar
    static let brandLeadingInset = AppTitlebarMetrics.trafficLightClearance
    static let extendsIntoNativeTitlebar = true
}

struct SettingsShell<Selection: Hashable, Sidebar: View, Detail: View>: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(SettingsNavigator.self) private var navigator
    @Binding var selection: Selection
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(spacing: 0) {
            titlebar

            HStack(spacing: 0) {
                sidebarColumn
                Divider()
                    .overlay(Color.aw.border)
                detailColumn
            }
        }
        .background(Color.aw.surface.window)
        // The navigator outlives this window. An intent noted but not yet
        // consumed when the window closes must not classify or scroll the
        // next ordinary opening.
        .onDisappear {
            navigator.clearPendingDeepLink()
        }
        // Floor is small enough to fit a low-vision-zoom screen but large
        // enough that the sidebar + a single content row remain usable.
        // Going to 0/0 lets the user shrink the window into a strip
        // where the sidebar and detail collide.
        .frame(
            minWidth: 480,
            idealWidth: AwSettings.preferredWindowSize.width,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: AwSettings.preferredWindowSize.height,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        // Match the primary window: the SwiftUI title bar occupies the native
        // title-bar row beneath AppKit's standard controls, rather than adding
        // a second visual band below it.
        .ignoresSafeArea(.container)
        // Transparent native title bar + full-size content. Scene-agnostic,
        // so it reaches the live Settings `NSWindow` the same way it does the
        // main window (`ContentView`). One source of truth for window chrome.
        .background(
            WindowChromeConfigurator(
                windowRole: .settings,
                reassertsOnBecomeKey: true,
                forcesTitlebarRelayout: true,
                assertsNonMainCapable: true,
                standardWindowButtonVisibility: .visible
            )
            .allowsHitTesting(false)
        )
    }

    /// In-content title bar with two zones mirroring the main window's
    /// `AppTitlebarView`: the Brandmark over the sidebar column and a quiet
    /// "Settings" label over the content column.
    private var titlebar: some View {
        HStack(spacing: 0) {
            brandZone
            contentZone
        }
        .frame(maxWidth: .infinity)
        .frame(height: SettingsTitlebarMetrics.height)
        .background {
            ZStack {
                LinearGradient(
                    colors: [Color.aw.surface.chrome2, Color.aw.surface.chrome],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    /// Brand anchored over the sidebar column. Fixed to the sidebar width so a
    /// window resize keeps the wordmark aligned with the column beneath it.
    /// Carries the "awesoMux Settings" header semantics moved off the old
    /// sidebar kicker.
    private var brandZone: some View {
        HStack(spacing: 0) {
            Brandmark()
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsTitlebarMetrics.brandLeadingInset)
        .padding(.trailing, 10)
        .frame(width: AwSettings.sidebarWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("awesoMux Settings")
        .accessibilityAddTraits(.isHeader)
    }

    /// Quiet "Settings" label anchored to the start of the content column,
    /// mirroring the main window's workspace-cluster placement past the
    /// divider. Non-interactive so it never competes with the band's drag.
    /// Hidden from accessibility: it is decorative chrome, and the brandZone
    /// header already carries the window identity — exposing it would make
    /// VoiceOver announce a redundant "Settings" after the header.
    private var contentZone: some View {
        HStack(spacing: 0) {
            Text("Settings")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppTitlebarMetrics.contentColumnGutter)
        .padding(.trailing, 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebar()
                .padding(.horizontal, 10)
                .padding(.top, AwSettings.contentInset.top)

            Spacer(minLength: 0)
        }
        .frame(width: AwSettings.sidebarWidth, alignment: .topLeading)
        .background(Color.aw.surface.sidebar)
    }

    private var detailColumn: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    detail()
                }
                .padding(AwSettings.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.aw.surface.window)
            .onChange(of: navigator.pendingScrollAnchor) {
                consumeScrollAnchor(proxy)
            }
            .onChange(of: navigator.mountedAnchors) {
                consumeScrollAnchor(proxy)
            }
            .onAppear {
                consumeScrollAnchor(proxy)
            }
        }
    }

    // Event-driven, deliberately without a timeout: the anchor's target
    // pane is usually still mounting when a deep link lands, so consumption
    // triggers on both anchor changes and mount registrations, and a target
    // that mounts late — or re-mounts after the user detours through
    // another pane — still gets its scroll. A timeout would strand the
    // pending anchor: re-selecting the same deep link re-assigns an equal
    // value, which `onChange` never reports. Consumption is synchronous;
    // deferring it through a Task hop loses the scroll when the hop is
    // starved (and buys nothing — `scrollTo` resolves against identity,
    // not current layout).
    private func consumeScrollAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = navigator.pendingScrollAnchor,
            navigator.mountedAnchors.contains(anchor)
        else { return }
        proxy.scrollTo(anchor, anchor: .top)
        navigator.pendingScrollAnchor = nil
        navigator.scrollDidLand(on: anchor)
    }
}
