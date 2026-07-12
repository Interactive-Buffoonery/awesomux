import Foundation
import AwesoMuxBridgeHelperSupport

let arguments = Array(CommandLine.arguments.dropFirst())
let status = BridgeHelperCommand.run(arguments: arguments)

exit(status)
