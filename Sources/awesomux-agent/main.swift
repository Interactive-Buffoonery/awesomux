import AwesoMuxLocalAPI
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let response: LocalAPIResponse
if arguments.count == 3, arguments[0] == "--profile",
    LocalAPIProfile.isValid(arguments[1]),
    let operation = LocalAPIOperation(rawValue: arguments[2])
{
    let request = LocalAPIRequest(profile: arguments[1], operation: operation)
    do {
        response = try LocalAPIClient.call(request)
    } catch {
        response = LocalAPIResponse(requestID: request.requestID, error: (error as? LocalAPIError) ?? .transportFailure)
    }
} else {
    response = LocalAPIResponse(error: .invalidRequest)
}
let data = try LocalAPIContract.encoder().encode(response)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
exit(response.error == nil ? 0 : 1)
