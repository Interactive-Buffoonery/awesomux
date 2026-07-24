import AwesoMuxCore
import Foundation
import os

public enum AgentHookCommand {
    // 1 MiB: a Claude Code PostToolUse payload embeds the full `tool_input`
    // (a Write carries the entire file `content`) plus `tool_response`, so a
    // 64 KiB cap dropped the whole event — and with it the touched-path
    // surfacing (issue #175) — for any moderately large Markdown write. This is
    // a one-shot hook process reading one payload, so a larger bound costs
    // nothing. Ceiling: a >1 MiB write still drops; raise again only if real
    // agent writes routinely exceed it.
    public static let maximumInputByteCount = 1024 * 1024

    private static let eventFileEnvironmentKey = AgentRuntimeEnvironmentKey.eventFile
    private static let decoder = JSONDecoder()
    private static let logger = Logger(subsystem: "awesomux.agent", category: "agent-hook")

    public static func shouldReadStandardInput(arguments: [String]) -> Bool {
        arguments != ["--health-check"] && arguments.first != "open-document"
    }

    public static func run(
        arguments: [String],
        environment: [String: String],
        stdin: Data,
        output: ((String) -> Void)? = nil,
        errorOutput: ((String) -> Void)? = nil
    ) -> Int {
        if arguments == ["--health-check"] {
            return AgentHookHealthCheck.run(
                environment: environment,
                output: output ?? writeStandardOutput,
                errorOutput: errorOutput ?? writeStandardError
            )
        }

        guard let invocation = parseInvocation(arguments: arguments) else {
            log(provider: nil, eventName: nil, category: "invalid-arguments")
            return 0
        }
        let provider = invocation.provider

        guard let eventFilePath = environment[eventFileEnvironmentKey],
            !eventFilePath.isEmpty
        else {
            log(provider: provider, eventName: nil, category: "missing-event-file")
            return 0
        }

        let event: AgentRuntimeEvent
        let eventName: String?
        switch invocation {
        case .hookPayload(let provider):
            guard stdin.count <= maximumInputByteCount else {
                log(provider: provider, eventName: nil, category: "oversized-input")
                return 0
            }

            guard let payload = try? decoder.decode(AgentHookPayload.self, from: stdin) else {
                log(provider: provider, eventName: nil, category: "invalid-json")
                return 0
            }

            guard let hookEventName = payload.hookEventName(for: provider) else {
                log(provider: provider, eventName: nil, category: "invalid-json")
                return 0
            }

            guard
                let mappedEvent = AgentHookEventMapper.event(
                    provider: provider,
                    hookEventName: hookEventName,
                    notificationType: payload.notificationType,
                    providerSessionID: provider == .grok ? payload.providerSessionID : nil,
                    reason: payload.reason,
                    toolName: payload.toolName,
                    toolFilePath: payload.toolFilePath
                )
            else {
                log(provider: provider, eventName: hookEventName, category: "unknown-event")
                return 0
            }
            event = mappedEvent
            eventName = hookEventName

        case .openDocument(let provider, let documentPath):
            guard let eventDocumentPath = AgentRuntimeEvent.validatedDocumentPath(documentPath) else {
                log(provider: provider, eventName: "open-document", category: "invalid-document-path")
                return 0
            }
            event = AgentRuntimeEvent(
                source: provider.source,
                kind: provider.kind,
                phase: .openDocument,
                eventID: UUID().uuidString,
                documentPath: eventDocumentPath,
                timestamp: Date()
            )
            eventName = "open-document"
        }

        do {
            var line = try event.hookJSONLineData()
            // A very long touched path can push the line past the JSONL cap. The
            // path is the droppable extra here; the lifecycle transition is not.
            // Re-encode without it so an oversized path degrades to "no link",
            // never to a lost `.toolEnd` (issue #175). `documentPath` is not
            // retried: an open-document event with no path has nothing to do.
            if line.count > AgentRuntimeEvent.maximumLineByteCount,
                event.touchedPath != nil
            {
                var trimmed = event
                trimmed.touchedPath = nil
                line = try trimmed.hookJSONLineData()
            }
            guard line.count <= AgentRuntimeEvent.maximumLineByteCount else {
                log(provider: provider, eventName: eventName, category: "oversized-payload")
                return 0
            }
            try AgentHookEventFileAppender.append(line, to: eventFilePath)
        } catch {
            log(provider: provider, eventName: eventName, category: "append-failed")
        }

        return 0
    }

    private static func parseInvocation(arguments: [String]) -> Invocation? {
        if arguments.first == "open-document" {
            guard arguments.count == 4,
                arguments[1] == "--provider",
                let provider = AgentHookProvider(rawValue: arguments[2])
            else {
                return nil
            }
            return .openDocument(provider: provider, documentPath: arguments[3])
        }

        guard arguments.count == 2,
            arguments[0] == "--provider",
            let provider = AgentHookProvider(rawValue: arguments[1])
        else {
            return nil
        }

        return .hookPayload(provider: provider)
    }

    private enum Invocation {
        case hookPayload(provider: AgentHookProvider)
        case openDocument(provider: AgentHookProvider, documentPath: String)

        var provider: AgentHookProvider {
            switch self {
            case .hookPayload(let provider), .openDocument(let provider, _):
                provider
            }
        }
    }

    private static func log(
        provider: AgentHookProvider?,
        eventName: String?,
        category: StaticString
    ) {
        logger.debug(
            "agent hook ignored provider=\(provider?.rawValue ?? "unknown", privacy: .public) event=\(eventName ?? "unknown", privacy: .public) category=\(category, privacy: .public)"
        )
    }

    private static func writeStandardOutput(_ message: String) {
        writeLine(message, to: .standardOutput)
    }

    private static func writeStandardError(_ message: String) {
        writeLine(message, to: .standardError)
    }

    private static func writeLine(_ message: String, to fileHandle: FileHandle) {
        var data = Data(message.utf8)
        data.append(0x0a)
        fileHandle.write(data)
    }
}
