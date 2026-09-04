import Foundation
import Testing

@testable import awesoMux

@Suite("Deployed plugin content comparison")
struct AgentPluginDeployedCopyInspectorTests {
    @Test("JSON object ordering and whitespace do not change deployed hook behavior")
    func ignoresObjectOrderingAndWhitespace() {
        let deployed = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo first","type":"command"}]}]}}"#.utf8)
        let rendered = Data(#"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo first" } ] } ] } }"#.utf8)

        #expect(!AgentPluginDeployedCopyInspector.contentDrift(deployed: deployed, rendered: rendered))
    }

    @Test("command contents and hook array order remain meaningful")
    func preservesBehaviorChanges() {
        let deployed = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo first"},{"command":"echo second"}]}]}}"#.utf8)
        let reordered = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo second"},{"command":"echo first"}]}]}}"#.utf8)
        let changed = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo changed"},{"command":"echo second"}]}]}}"#.utf8)

        #expect(AgentPluginDeployedCopyInspector.contentDrift(deployed: deployed, rendered: reordered))
        #expect(AgentPluginDeployedCopyInspector.contentDrift(deployed: deployed, rendered: changed))
    }

    @Test("invalid hook objects cannot be accepted as matching", arguments: ["{", "[]", "null"])
    func rejectsInvalidObjects(json: String) {
        let invalid = Data(json.utf8)
        #expect(AgentPluginDeployedCopyInspector.contentDrift(deployed: invalid, rendered: invalid))
    }
}
