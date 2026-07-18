import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct AnalyticsSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(AnalyticsPipelineClient.self) private var analyticsClient
    @State private var isDisableDialogPresented = false
    @State private var isDeleteLogDialogPresented = false
    @State private var consentAtDisableDialog: AnalyticsConfig.ConsentLevel?
    @State private var statusMessage: String?

    private var consent: AnalyticsConfig.ConsentLevel {
        appSettingsStore.analytics.value.consentLevel
    }

    /// Routing binding: raising consent applies immediately; dropping to
    /// off first asks what to do with retained local analytics data, per
    /// INT-768 (recommended default: delete).
    private var consentSelection: Binding<AnalyticsConfig.ConsentLevel> {
        Binding(
            get: { consent },
            set: { newLevel in
                guard newLevel != consent else { return }
                // While the disk config is invalid, section edits commit
                // in memory without persisting. Every other setting may
                // float until the user repairs the file, but consent must
                // not: opting in mints a durable distinct id and log
                // entries for a choice that evaporates on relaunch.
                guard !appSettingsStore.isDiskConfigInvalid else {
                    confirmStatus(Self.saveFailedMessage)
                    return
                }
                if newLevel == .off {
                    consentAtDisableDialog = consent
                    isDisableDialogPresented = true
                } else {
                    appSettingsStore.analytics.update { $0.consentLevel = newLevel }
                    // update commits only when the persist succeeds; opting the
                    // client in on a failed save would mint a distinct id for a
                    // consent level that is not actually recorded anywhere.
                    guard consent == newLevel else {
                        confirmStatus(Self.saveFailedMessage)
                        return
                    }
                    analyticsClient.optIn(level: newLevel)
                    confirmStatus(Self.enabledMessage(for: newLevel))
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: String(localized: "Consent", comment: "Analytics settings section title"),
                subtitle: Self.privacySummary
            ) {
                SettingsField(
                    label: String(localized: "Share anonymous analytics", comment: "Analytics consent field label"),
                    hint: Self.consentHint,
                    isFirst: true
                ) {
                    SettingsSegmented(options: consentOptions, selection: consentSelection)
                        .disabled(appSettingsStore.isDiskConfigInvalid)
                        .accessibilityLabel(
                            String(localized: "Analytics consent level", comment: "VoiceOver label for the analytics consent picker")
                        )
                        .accessibilityHint(
                            appSettingsStore.isDiskConfigInvalid
                                ? String(
                                    localized: "Fix the invalid config file before changing analytics consent.",
                                    comment: "VoiceOver hint on the disabled analytics consent picker")
                                : ""
                        )
                }
            }

            SettingsSection(
                index: 2,
                title: String(localized: "Local event log", comment: "Analytics settings section title")
            ) {
                SettingsField(
                    label: String(localized: "Event log", comment: "Analytics view-events field label"),
                    hint: String(
                        localized: "Opens the diagnostics panel showing each event's final payload and delivery status.",
                        comment: "Analytics view-events field hint"
                    ),
                    isFirst: true
                ) {
                    Button(String(localized: "View Analytics Events", comment: "Button opening diagnostics analytics log")) {
                        navigator.pendingScrollAnchor = DiagnosticsSettingsPane.analyticsEventsAnchor
                        navigator.noteAnalyticsDiagnosticsIntent(.analytics)
                        navigator.pendingSection = .diagnostics
                    }
                }

                SettingsField(
                    label: String(localized: "Test event", comment: "Analytics test event field label"),
                    hint: String(
                        localized:
                            "Submits one diagnostic test event through the redaction pipeline so you can inspect its final event properties and request status.",
                        comment: "Analytics test event field hint"
                    )
                ) {
                    Button(String(localized: "Send Test Diagnostic Event", comment: "Button emitting an analytics test event")) {
                        analyticsClient.capture(.testPing)
                        TerminalAccessibilityAnnouncer.announce(
                            String(
                                localized: "Test event processed. Review its request status under Analytics events in Diagnostics.",
                                comment: "VoiceOver announcement after sending an analytics test event"
                            )
                        )
                    }
                    .disabled(consent == .off || appSettingsStore.isDiskConfigInvalid)
                    .accessibilityHint(testEventAccessibilityHint)
                }

                SettingsField(
                    label: String(localized: "Delete log", comment: "Analytics delete log field label"),
                    hint: String(
                        localized: "Removes the local analytics event log and resets the anonymous analytics identifier.",
                        comment: "Analytics delete log field hint"
                    )
                ) {
                    Button(
                        String(localized: "Delete Analytics Event Log", comment: "Button deleting the analytics event log"),
                        role: .destructive
                    ) {
                        isDeleteLogDialogPresented = true
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text)
                    .padding(.top, 8)
            }
        }
        .confirmationDialog(
            String(localized: "Turn off analytics?", comment: "Disable-analytics dialog title"),
            isPresented: $isDisableDialogPresented,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    localized: "Delete Data (Recommended)",
                    comment: "Disable-analytics dialog: recommended action to delete local analytics data"), role: .destructive
            ) {
                confirmDisable(deleteLocalState: true)
            }
            Button(String(localized: "Keep Data", comment: "Disable-analytics dialog: keep local analytics data")) {
                confirmDisable(deleteLocalState: false)
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel button"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "New analytics capture stops immediately, though a request already in flight may finish. Deleting also removes the local event log and the anonymous identifier.",
                    comment: "Disable-analytics dialog message"
                )
            )
        }
        .confirmationDialog(
            String(localized: "Delete the analytics event log?", comment: "Delete-analytics-log dialog title"),
            isPresented: $isDeleteLogDialogPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", comment: "Delete-analytics-log dialog confirm button"), role: .destructive) {
                confirmDeletion(analyticsClient.deleteLocalAnalyticsState())
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel button"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "Removes all locally recorded analytics events and resets the anonymous analytics identifier.",
                    comment: "Delete-analytics-log dialog message"
                )
            )
        }
    }

    /// A config reload can change consent while the dialog is open (dotfiles
    /// sync, hand edit); a stale answer must not clobber it, and destructive
    /// deletion only follows a consent change that actually persisted.
    private func confirmDisable(deleteLocalState: Bool) {
        defer { consentAtDisableDialog = nil }
        guard consent == consentAtDisableDialog else {
            confirmStatus(
                String(
                    localized: "Analytics consent changed while the dialog was open. Review the current setting and try again.",
                    comment: "Status after a stale disable-analytics dialog was discarded")
            )
            return
        }
        if consent != .off {
            appSettingsStore.analytics.update { $0.consentLevel = .off }
            guard consent == .off else {
                confirmStatus(Self.saveFailedMessage)
                return
            }
        }

        let deletionSucceeded = analyticsClient.optOut(deleteLocalState: deleteLocalState)
        if deleteLocalState {
            confirmDeletion(deletionSucceeded)
        } else {
            confirmStatus(
                String(
                    localized: "Analytics off. Retained local events were kept.",
                    comment: "Confirmation after disabling analytics while keeping local data")
            )
        }
    }

    private func confirmDeletion(_ succeeded: Bool) {
        confirmStatus(
            succeeded
                ? String(
                    localized: "Analytics event log deleted and identifier reset.",
                    comment: "Confirmation after deleting local analytics state")
                : String(
                    localized: "Some local analytics data could not be deleted. Check file permissions and try again.",
                    comment: "Failure after deleting local analytics state")
        )
    }

    private func confirmStatus(_ message: String) {
        statusMessage = message
        TerminalAccessibilityAnnouncer.announce(message)
    }

    private var testEventAccessibilityHint: String {
        if appSettingsStore.isDiskConfigInvalid {
            return String(
                localized: "Fix the invalid config file before sending a test event.",
                comment: "VoiceOver hint on analytics test event disabled by invalid config")
        }
        if consent == .off {
            return String(
                localized: "Enable analytics consent above to send a test event.",
                comment: "VoiceOver hint on the disabled analytics test event button")
        }
        return ""
    }

    private static func enabledMessage(for level: AnalyticsConfig.ConsentLevel) -> String {
        switch level {
        case .errorReports:
            String(
                localized: "Analytics on — allowing sanitized handled-error events only.",
                comment: "Confirmation after enabling error-report analytics")
        case .productUsage:
            String(
                localized: "Analytics on — allowing sanitized handled-error and product-usage events.",
                comment: "Confirmation after enabling product-usage analytics")
        case .off:
            String(localized: "Analytics off.", comment: "Analytics disabled status")
        }
    }

    private static var saveFailedMessage: String {
        String(
            localized: "Couldn't save the analytics setting. Check that config.toml is writable.",
            comment: "Analytics consent save failure message")
    }

    private var consentOptions: [SettingsSegmented<AnalyticsConfig.ConsentLevel>.Option] {
        [
            .init(
                value: .off,
                label: String(localized: "Off", comment: "Analytics consent level: off"),
                accessibilityLabel: String(localized: "Analytics off")
            ),
            .init(
                value: .errorReports,
                label: String(localized: "Error reports", comment: "Analytics consent level: error reports"),
                accessibilityLabel: String(localized: "Allow sanitized error reports only")
            ),
            .init(
                value: .productUsage,
                label: String(localized: "Product usage", comment: "Analytics consent level: product usage"),
                accessibilityLabel: String(localized: "Allow sanitized error reports and product usage")
            ),
        ]
    }

    private static var privacySummary: String {
        String(
            localized: """
                Analytics are off by default, with no PostHog connection until you opt in. When enabled, \
                awesoMux submits only final post-redaction events under a random analytics identifier that is \
                not tied to your name or account. PostHog receives ordinary request metadata, but awesoMux \
                disables GeoIP enrichment. Current delivery is limited to consent changes, user-triggered test \
                events, app and operating-system versions, CPU architecture, named handled-error categories \
                with coarse remote context, and the Diagnostics section opened. It never includes terminal \
                content, commands, prompts, paths, hostnames, or direct identifiers.
                """,
            comment: "Analytics consent section privacy summary"
        )
    }

    private static var consentHint: String {
        String(
            localized:
                "Choose whether to submit only allowlisted handled-error events, or those events plus allowlisted app launch and Diagnostics usage events.",
            comment: "Analytics consent field hint"
        )
    }
}
