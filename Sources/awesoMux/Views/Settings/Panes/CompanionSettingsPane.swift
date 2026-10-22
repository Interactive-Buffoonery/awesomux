import AppKit
import AwesoMuxCore
import AwesoMuxLocalAPIAccess
import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import SwiftUI

struct CompanionSettingsPane: View {
    @Environment(CompanionPairingCoordinator.self) private var coordinator
    @State private var showsPairing = false
    @State private var pendingUnpair: LocalAPIConnectionGrant?
    @State private var errorMessage: String?

    var body: some View {
        SettingsSection(
            index: 1,
            title: String(localized: "awesoMux Companion", comment: "Companion settings title."),
            subtitle: String(
                localized:
                    "Paired iPhones can see every workspace and pane’s status. Terminal previews share each terminal’s last output line and may contain sensitive content. Existing phones start with previews off; each phone can also turn its own previews on or off. Pane renaming is available with your permission.",
                comment: "Companion settings description."
            ),
            badge: String(localized: "Alpha", comment: "Companion prerelease badge.")
        ) {
            SettingsField(
                label: String(localized: "iPhone app", comment: "Companion TestFlight row label."),
                isFirst: true
            ) {
                // Becomes a TestFlight link once the public link exists.
                Text(String(localized: "Coming soon to TestFlight", comment: "Companion iPhone app availability."))
                    .awFont(AwFont.UI.meta)
            }

            SettingsField(
                label: String(localized: "Paired phones", comment: "Companion paired-phone list label."),
                hint: listeningFooter
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if coordinator.pairedPhones.isEmpty {
                        Text(String(localized: "No iPhone paired", comment: "Companion empty state."))
                            .awFont(AwFont.UI.meta)
                            .foregroundStyle(Color.aw.text2)
                    } else {
                        ForEach(coordinator.pairedPhones) { phone in
                            phoneRow(phone)
                        }
                    }

                    Button(String(localized: "Pair iPhone…", comment: "Start Companion pairing button.")) {
                        showsPairing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(String(localized: "Shows a QR code and pairing link."))
                }
            }

            if let visibleError {
                SettingsField(
                    label: String(localized: "Companion unavailable", comment: "Companion error label."),
                    hint: visibleError,
                    hintColor: Color.aw.status.needs
                ) {
                    if coordinator.persistenceFailureMessage != nil {
                        Button(String(localized: "Retry Save", comment: "Retry Companion metadata save.")) {
                            retryPersistence()
                        }
                    } else {
                        Button(String(localized: "Dismiss", comment: "Dismiss Companion error.")) {
                            errorMessage = nil
                            coordinator.clearListenerError()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showsPairing, onDismiss: coordinator.cancelPairing) {
            CompanionPairingSheet()
        }
        .onChange(of: visibleError) { _, message in
            guard let message else { return }
            let announcement =
                coordinator.persistenceFailureMessage == nil
                ? message
                : message + " " + String(localized: "Retry Save", comment: "Retry Companion metadata save.")
            AccessibilityNotification.Announcement(announcement).post()
        }
        .confirmationDialog(
            String(localized: "Unpair iPhone?", comment: "Companion unpair confirmation title."),
            isPresented: Binding(
                get: { pendingUnpair != nil },
                set: { if !$0 { pendingUnpair = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnpair
        ) { phone in
            Button(String(localized: "Unpair", comment: "Confirm Companion unpair button."), role: .destructive) {
                do {
                    try coordinator.unpair(phone)
                } catch {
                    errorMessage = String(localized: "awesoMux couldn't unpair this iPhone. Try again.")
                }
                pendingUnpair = nil
            }
        } message: { phone in
            Text(
                String.localizedStringWithFormat(
                    String(localized: "%@ will lose access right away.", comment: "Companion unpair confirmation message."),
                    phone.label
                )
            )
        }
    }

    private var visibleError: String? {
        coordinator.persistenceFailureMessage ?? coordinator.listenerErrorMessage ?? errorMessage
    }

    private var listeningFooter: String? {
        let transports = coordinator.boundAddresses.map(\.transport)
        if transports.contains(.lan), transports.contains(.tailscale) {
            return String(
                localized: "Listening on local network and Tailscale", comment: "Companion active LAN and Tailscale transports footer.")
        }
        if transports.contains(.lan) {
            return String(localized: "Listening on local network only", comment: "Companion active LAN transport footer.")
        }
        if transports.contains(.tailscale) {
            return String(localized: "Listening on Tailscale only", comment: "Companion active Tailscale transport footer.")
        }
        return nil
    }

    private func phoneRow(_ phone: LocalAPIConnectionGrant) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(phone.label)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                Spacer(minLength: 12)
                Button(String(localized: "Unpair…", comment: "Companion unpair button.")) {
                    pendingUnpair = phone
                }
                .accessibilityLabel(
                    String.localizedStringWithFormat(String(localized: "Unpair %@"), phone.label)
                )
            }
            Toggle(
                String.localizedStringWithFormat(
                    String(localized: "Terminal previews for %@", comment: "Per-phone Companion terminal preview switch."), phone.label
                ),
                isOn: Binding(
                    get: { coordinator.pairedPhones.first(where: { $0.id == phone.id })?.companion?.terminalPreviewAllowed ?? false },
                    set: { allowed in
                        do {
                            try coordinator.updateTerminalPreviewAllowed(allowed, for: phone.id)
                            errorMessage = nil
                        } catch {
                            errorMessage = String(
                                localized: "Could not save terminal preview access. Retry Save before restarting awesoMux.",
                                comment: "Companion preview permission save error.")
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .help(
                String(
                    localized: "Shares the last output line from every terminal. This iPhone can also change its own preview setting.",
                    comment: "Companion terminal preview switch help."))
            if let pairedAt = phone.companion?.pairedAt {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Paired %@", comment: "Companion paired date."),
                        pairedAt.formatted(date: .abbreviated, time: .omitted)
                    )
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
            }
            Toggle(
                isOn: Binding(
                    get: { phone.companion?.paneRenameScope != nil },
                    set: { allowed in
                        do {
                            try coordinator.setPaneRenameAllowed(allowed, for: phone)
                        } catch {
                            errorMessage = String(localized: "awesoMux couldn't save the pane rename permission.")
                        }
                    }
                )
            ) {
                Text(String(localized: "Allow pane renaming"))
            }
            .accessibilityLabel(
                String.localizedStringWithFormat(String(localized: "Allow pane renaming for %@"), phone.label))
            Text(String(localized: "Lets this phone rename terminal panes within its visible workspaces."))
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
            Menu(
                String(
                    localized: "Decision workspaces",
                    comment: "Menu for selecting which workspaces this paired phone may answer permission requests for.")
            ) {
                ForEach(coordinator.decisionWorkspaces, id: \.id) { workspace in
                    Toggle(
                        workspace.name,
                        isOn: Binding(
                            get: {
                                coordinator.pairedPhones.first { $0.id == phone.id }?.companion?.decideWorkspaceIDs?.contains(workspace.id)
                                    == true
                            },
                            set: { allowed in
                                do {
                                    try coordinator.setDecisionWorkspace(workspace.id, allowed: allowed, for: phone.id)
                                    errorMessage = nil
                                } catch {
                                    errorMessage = String(
                                        localized: "Could not save decision access.",
                                        comment: "Error shown when saving a paired phone’s workspace decision permission fails.")
                                }
                            }))
                }
            }
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    String(
                        localized: "Decision workspaces for %@",
                        comment: "Accessibility label for a paired phone’s decision workspace menu. Argument is the phone’s name."),
                    phone.label))
            Text(
                String(
                    localized: "Remote decisions are not available yet. Workspace access starts off.",
                    comment: "Explains that remote permission decisions are not released and workspace access is disabled by default.")
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text3)
            Toggle(
                isOn: Binding(
                    get: { phone.companion?.terminalWatchScope != nil },
                    set: { allowed in
                        do {
                            try coordinator.setTerminalWatchAllowed(allowed, for: phone)
                            errorMessage = nil
                        } catch {
                            errorMessage = String(localized: "awesoMux couldn't save the terminal watch permission.")
                        }
                    }
                )
            ) {
                Text(String(localized: "Allow watching terminals"))
            }
            .accessibilityLabel(
                String.localizedStringWithFormat(String(localized: "Allow watching terminals for %@"), phone.label))
            Text(
                String(
                    localized: "Streams live terminal output, which can include secrets, to this phone. It cannot type.")
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text)
            Text(lastSeenText(phone.id))
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
        }
        .padding(10)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay { RoundedRectangle(cornerRadius: AwRadius.button).stroke(Color.aw.border, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private func lastSeenText(_ id: UUID) -> String {
        guard let date = coordinator.lastSeen[id] else {
            return String(localized: "Last seen: not yet this launch", comment: "Companion last-seen empty value.")
        }
        return String.localizedStringWithFormat(
            String(localized: "Last seen %@", comment: "Companion last-seen date."),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func retryPersistence() {
        do {
            try coordinator.retryPersistence()
            errorMessage = nil
        } catch {
            errorMessage =
                coordinator.persistenceFailureMessage
                ?? String(localized: "awesoMux couldn't save the Companion access change.")
        }
    }
}

private struct CompanionPairingSheet: View {
    @Environment(CompanionPairingCoordinator.self) private var coordinator
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var errorMessage: String?
    @State private var qrImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Pair iPhone", comment: "Companion pairing sheet title."))
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)
                .accessibilityAddTraits(.isHeader)

            if let session = coordinator.pairingSession, coordinator.currentPairingLink != nil {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .accessibilityLabel(String(localized: "QR code for pairing awesoMux Companion"))
                        .accessibilityHint(String(localized: "Scan this code with the iPhone Camera app."))
                        .frame(maxWidth: .infinity)
                }

                Text(expiryText(session.expiresAt))
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button(String(localized: "Copy Link", comment: "Copy Companion pairing link button.")) {
                    NSPasteboard.general.clearContents()
                    if !NSPasteboard.general.setString(session.link, forType: .string) {
                        errorMessage = String(localized: "The pairing link couldn't be copied.")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(String(localized: "Copies the one-time pairing link."))
                .frame(maxWidth: .infinity)
                if let errorMessage {
                    Text(errorMessage)
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.status.needs)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let terminalMessage {
                Text(terminalMessage)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button(String(localized: "Create New Code", comment: "Restart Companion pairing button.")) {
                    Task { await startPairing() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } else if let session = coordinator.pairingSession {
                Text(
                    String(
                        localized: "Waiting for a local network or Tailscale address…",
                        comment: "Companion pairing waiting for a network route.")
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)

                Text(expiryText(session.expiresAt))
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let errorMessage {
                Text(errorMessage)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.status.needs)
                    .fixedSize(horizontal: false, vertical: true)

                Button(String(localized: "Try Again", comment: "Retry starting Companion pairing button.")) {
                    Task { await startPairing() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView()
                    .accessibilityLabel(String(localized: "Creating pairing code"))
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button(String(localized: "Close", comment: "Close Companion pairing sheet.")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            await startPairing()
        }
        .task(id: coordinator.currentPairingLink) {
            qrImage = coordinator.currentPairingLink.flatMap { Self.qrImage(for: $0) }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: coordinator.pairingResult) { _, result in
            if result == .paired { dismiss() }
        }
        .alert(
            approvalTitle,
            isPresented: Binding(
                get: { coordinator.approvalPrompt != nil },
                set: { _ in }
            ),
            presenting: coordinator.approvalPrompt
        ) { _ in
            Button(String(localized: "Don't Allow", comment: "Deny Companion pairing button."), role: .cancel) {
                coordinator.denyPendingPhone()
            }
            Button(String(localized: "Allow", comment: "Allow Companion pairing button.")) {
                coordinator.allowPendingPhone()
            }
        } message: { prompt in
            Text(
                String(
                    localized:
                        "Allow enables this iPhone to see every workspace and pane’s status and each terminal’s last output line. Terminal content may be sensitive. You can turn previews off in Companion settings; this phone can also change its own setting. Confirm these words match your iPhone:",
                    comment: "Companion approval content disclosure.")
                    + "\n\n" + prompt.words.joined(separator: "   ")
            )
        }
    }

    private var approvalTitle: String {
        guard let prompt = coordinator.approvalPrompt else {
            return String(localized: "Allow this iPhone?", comment: "Fallback Companion approval title.")
        }
        return String.localizedStringWithFormat(
            String(localized: "Allow “%@” to see panes and terminal previews?", comment: "Companion approval title."),
            prompt.phoneName
        )
    }

    private var terminalMessage: String? {
        switch coordinator.pairingResult {
        case .denied:
            String(localized: "Pairing wasn't allowed. Create a new code to try again.")
        case .expired:
            String(localized: "This pairing code expired.")
        case .paired, nil:
            nil
        }
    }

    private func startPairing() async {
        do {
            errorMessage = nil
            _ = try await coordinator.beginPairing()
        } catch CompanionPairingError.noLocalAddress {
            errorMessage = String(
                localized: "This Mac doesn't currently have a local network or Tailscale address.",
                comment: "Companion pairing start error when no route exists."
            )
        } catch {
            errorMessage = String(localized: "Companion pairing could not start.")
        }
    }

    private func expiryText(_ expiresAt: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now)))
        return String.localizedStringWithFormat(
            String(localized: "Expires in %@", comment: "Companion pairing countdown."),
            String(format: "%d:%02d", seconds / 60, seconds % 60)
        )
    }

    private static func qrImage(for link: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
