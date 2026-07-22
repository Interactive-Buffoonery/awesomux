#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import AwesoMuxBridgeHelperSupport

let arguments = Array(CommandLine.arguments.dropFirst())
let status = BridgeHelperCommand.run(arguments: arguments)

exit(status)
