import AwesoMuxBridgeProtocol
import Foundation

/// Best-effort identity from the input/footer region of the active screen.
/// The caller must prove an unmanaged SSH foreground and exclude hook identity.
public enum UnmanagedSSHAgentIdentity {
    public static func detectedKind(inActiveText text: String) -> AgentKind? {
        let lines = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let footerLines = Array(
            lines.drop(while: { $0.isEmpty }).reversed()
                .drop(while: { $0.isEmpty }).reversed().suffix(8))
        guard let footer = footerLines.last else { return nil }

        if footer.hasPrefix("← for agents"), footer.hasSuffix("? for shortcuts"),
            let promptIndex = footerLines.dropLast().lastIndex(where: { $0.hasPrefix("› ") }),
            footerLines.count - promptIndex <= 4
        {
            let prompt = footerLines[promptIndex]
            let hasModelStatus = footerLines[(promptIndex + 1)..<(footerLines.count - 1)]
                .contains { $0.hasPrefix("gpt-") && $0.contains(" · ") }
            if prompt == "› ask codex to do anything" || hasModelStatus {
                return .codex
            }
        }

        let hasClaudeFooter =
            footer == "? for shortcuts"
            || ((footer.hasPrefix("⏵⏵ bypass permissions on")
                || footer.hasPrefix("⏵⏵ accept edits on")
                || footer.hasPrefix("⏸ plan mode on"))
                && footer.contains("shift+tab to cycle"))
        guard hasClaudeFooter, footerLines.count >= 4 else { return nil }
        let input = footerLines.suffix(4)
        let prompt = input[input.index(after: input.startIndex)]
        guard isInputBorder(input[input.startIndex]),
            prompt == "❯" || prompt.hasPrefix("❯ "),
            isInputBorder(input[input.index(input.startIndex, offsetBy: 2)])
        else { return nil }
        return .claudeCode
    }

    private static func isInputBorder(_ line: String) -> Bool {
        line.count >= 5 && line.allSatisfy { $0 == "─" }
    }
}
