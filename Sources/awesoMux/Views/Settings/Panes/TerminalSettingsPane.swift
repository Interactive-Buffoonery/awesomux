import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct TerminalSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(index: 1, title: "Cursor") {
                SettingsField(
                    label: "Cursor style",
                    hint: "Style picker lands once the runtime exposes a setter.",
                    isFirst: true
                ) {
                    Text("Block (libghostty default)")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text2)
                }

                SettingsField(
                    label: "Cursor glow",
                    hint: "Adds an accent halo to the chrome cursor indicator. Does not affect the libghostty surface cursor.",
                    // Bare .labelsHidden() Toggle — let the field supply its name.
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Cursor glow", isOn: appSettingsStore.appearance.binding(\.cursorGlow))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(index: 2, title: "CRT effect", subtitle: "Optional retro overlay on the terminal pane.") {
                SettingsField(
                    label: "CRT scanlines",
                    hint: "Visual-only overlay. Off by default.",
                    isFirst: true,
                    // Bare .labelsHidden() Toggle — let the field supply its name.
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("CRT scanlines", isOn: appSettingsStore.appearance.binding(\.crtScanlines))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(
                index: 3,
                title: "Clipboard",
                subtitle: "What terminal programs may read or write, and whether selecting text copies it. These controls are independent."
            ) {
                SettingsField(
                    label: "Program writes (OSC 52)",
                    hint: "Applies when terminal output asks awesoMux to replace the clipboard, including SSH and agent sessions. Commands like pbcopy write to macOS directly.",
                    isFirst: true
                ) {
                    SettingsSegmented(
                        options: clipboardWritePolicyOptions,
                        selection: appSettingsStore.terminal.binding(\.clipboardWritePolicy)
                    )
                    // The selected segment already exposes its own label + the
                    // `.isSelected` trait, so a container `.accessibilityValue`
                    // here would make VoiceOver announce the selection twice
                    // (the group is `.contain`, not `.combine`). Group label +
                    // hint give orientation; the children carry the value.
                    .accessibilityLabel("Terminal program clipboard writes")
                    .accessibilityHint("Controls whether terminal programs and escape sequences can replace the macOS clipboard.")
                }

                SettingsField(
                    label: "Program reads (OSC 52)",
                    hint: "Asks before terminal escape sequences can read the clipboard. Turning this off denies those reads without prompting.",
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle(
                        "Ask before terminal programs read the clipboard",
                        isOn: appSettingsStore.terminal.binding(\.confirmClipboardRead)
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsField(
                    label: "Highlight to copy",
                    // Independent of the policy above on purpose: this is your own
                    // selection, not a program write, so it copies even when
                    // program writes are denied. Name the privacy blast radius —
                    // the people most likely to enable it have secrets on screen.
                    hint: "Copies text you select to the clipboard. Because it's your own selection it copies regardless of the program-writes setting above, and may sync to your other devices via Universal Clipboard. \"System default\" defers to Ghostty (on, for macOS)."
                ) {
                    SettingsSegmented(
                        options: copyOnSelectOptions,
                        selection: appSettingsStore.terminal.binding(\.copyOnSelect)
                    )
                    .accessibilityLabel("Highlight to copy")
                    .accessibilityHint("Whether selecting terminal text automatically copies it to the macOS clipboard.")
                }
            }

            SettingsSection(
                index: 4,
                title: "Background sessions",
                subtitle: "Terminal sessions can keep running in the background through the command bridge, surviving a closed pane and reattaching later — including agent sessions. Optionally clean up ones that have been idle too long."
            ) {
                SettingsField(
                    label: "Keep sessions running in the background",
                    hint: "Runs new terminal panes through the amx command bridge so a session keeps running when its pane closes and can reattach later. Takes effect when a pane opens or recreates its terminal; already-open panes keep their current mode until they close or awesoMux relaunches.",
                    isFirst: true,
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Keep terminal sessions running in the background", isOn: appSettingsStore.terminal.binding(\.commandBridgeEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: "Auto-clean up at launch",
                    hint: "Removes background sessions that have been idle longer than the threshold. Runs once each time awesoMux launches.",
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Auto-clean up idle background sessions at launch", isOn: appSettingsStore.terminal.binding(\.daemonIdleCapEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: "Idle threshold",
                    hint: "Sessions idle for at least this long are eligible for removal on next launch. Only applies when auto-clean up is on."
                ) {
                    Stepper(
                        capDaysLabel,
                        value: capDaysBinding,
                        in: 1...90
                    )
                    .disabled(!appSettingsStore.terminal.value.daemonIdleCapEnabled)
                    .accessibilityLabel("Idle threshold in days")
                    .accessibilityHint("Sessions idle longer than this threshold are cleaned up at launch.")
                }
            }
        }
    }

    private var capDaysBinding: Binding<Int> {
        Binding(
            get: { appSettingsStore.terminal.value.daemonIdleCapMinutes / 1440 },
            set: { days in appSettingsStore.terminal.update { $0.daemonIdleCapMinutes = max(1, days) * 1440 } }
        )
    }

    private var capDaysLabel: String {
        let days = appSettingsStore.terminal.value.daemonIdleCapMinutes / 1440
        return LocalizedPluralStrings.terminalCapDays(count: days)
    }

    private var copyOnSelectOptions: [SettingsSegmented<TerminalConfig.CopyOnSelect>.Option] {
        [
            .init(
                value: .inherit,
                label: "System default",
                accessibilityLabel: "Defer to Ghostty's default highlight-to-copy behavior"
            ),
            .init(
                value: .off,
                label: "Off",
                accessibilityLabel: "Never copy selections automatically"
            ),
            .init(
                value: .on,
                label: "On",
                accessibilityLabel: "Always copy selections to the clipboard"
            )
        ]
    }

    private var clipboardWritePolicyOptions: [SettingsSegmented<TerminalConfig.ClipboardWritePolicy>.Option] {
        [
            .init(
                value: .ask,
                label: "Ask",
                accessibilityLabel: "Ask before terminal clipboard writes"
            ),
            .init(
                value: .allow,
                label: "Allow",
                accessibilityLabel: "Always allow terminal clipboard writes"
            ),
            .init(
                value: .deny,
                label: "Deny",
                accessibilityLabel: "Always deny terminal clipboard writes"
            )
        ]
    }
}
