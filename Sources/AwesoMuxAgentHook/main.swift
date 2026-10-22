import Foundation
import AwesoMuxAgentHookSupport

// A broken provider pipe must fail the write and leave delivery unacknowledged.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
let input = AgentHookCommand.shouldReadStandardInput(arguments: arguments)
    ? AgentHookInputReader.read(
        fileDescriptor: STDIN_FILENO,
        maximumByteCount: AgentHookCommand.maximumInputByteCount,
        idleTimeoutMilliseconds: 500
    )
    : Data()

let status = AgentHookCommand.run(
    arguments: arguments,
    environment: ProcessInfo.processInfo.environment,
    stdin: input
)

exit(Int32(status))
