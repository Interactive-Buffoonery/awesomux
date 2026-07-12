import Foundation
import AwesoMuxAgentHookSupport

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
