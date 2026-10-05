import AwesoMuxLocalAPI
import AwesoMuxLocalAPICredentials
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if let credentialCommand = CredentialCommand(arguments: arguments) {
    let error = credentialCommand.run()
    let payload: [String: Any] = error == nil ? ["ok": true] : ["error": error!.rawValue]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(error == nil ? 0 : 1)
}

let response: LocalAPIResponse
if [5, 7, 9, 13].contains(arguments.count), arguments[0] == "--profile",
    LocalAPIProfile.isValid(arguments[1]),
    arguments[2] == "--credential-handle",
    let connectionID = UUID(uuidString: arguments[3]),
    let operation = LocalAPIOperation(rawValue: arguments[4])
{
    do {
        var paneID: UUID?
        var targetVersion: UUID?
        var limit: Int?
        var source: LocalAPIContextSource?
        var cursor: String?
        if operation == .agentContext {
            guard arguments.count == 13, arguments[5] == "--pane-id",
                let parsedPaneID = UUID(uuidString: arguments[6]),
                arguments[7] == "--target-version", let parsedVersion = UUID(uuidString: arguments[8]),
                arguments[9] == "--limit", let parsedLimit = Int(arguments[10]), parsedLimit > 0,
                arguments[11] == "--source", let parsedSource = LocalAPIContextSource(rawValue: arguments[12])
            else { throw LocalAPIError.invalidRequest }
            paneID = parsedPaneID
            targetVersion = parsedVersion
            limit = parsedLimit
            source = parsedSource
        } else if operation == .attentionEvents {
            guard [7, 9].contains(arguments.count), arguments[5] == "--limit",
                let parsedLimit = Int(arguments[6]), parsedLimit > 0
            else { throw LocalAPIError.invalidRequest }
            limit = parsedLimit
            if arguments.count == 9 {
                guard arguments[7] == "--cursor", !arguments[8].isEmpty, arguments[8].utf8.count <= 2048
                else { throw LocalAPIError.invalidRequest }
                cursor = arguments[8]
            }
        } else if arguments.count != 5 {
            throw LocalAPIError.invalidRequest
        }
        let credential = try LocalAPICredentialKeychain.load(profile: arguments[1], connectionID: connectionID)
        guard let encodedCredential = LocalAPICredential.encode(credential) else {
            throw LocalAPICredentialKeychainError.invalidCredential
        }
        let request = LocalAPIRequest(
            profile: arguments[1],
            operation: operation,
            connectionID: connectionID,
            credential: encodedCredential,
            paneID: paneID, targetVersion: targetVersion, limit: limit, source: source, cursor: cursor
        )
        do {
            response = try LocalAPIClient.call(request)
        } catch {
            let apiError = error as? LocalAPIError
            response = LocalAPIResponse(
                requestID: request.requestID,
                error: apiError == .cancelled ? .transportFailure : (apiError ?? .transportFailure)
            )
        }
    } catch {
        response = LocalAPIResponse(error: error as? LocalAPIError ?? .credentialUnavailable)
    }
} else {
    response = LocalAPIResponse(error: .invalidRequest)
}
let data = try LocalAPIContract.encoder().encode(response)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
exit(response.error == nil ? 0 : 1)

private struct CredentialCommand {
    enum Action {
        case store
        case delete
    }

    let action: Action
    let profile: String
    let connectionID: UUID

    init?(arguments: [String]) {
        guard arguments.count == 6,
            arguments[0] == "credential",
            arguments[2] == "--profile",
            LocalAPIProfile.isValid(arguments[3]),
            arguments[4] == "--credential-handle",
            let connectionID = UUID(uuidString: arguments[5])
        else { return nil }
        switch arguments[1] {
        case "store": action = .store
        case "delete": action = .delete
        default: return nil
        }
        profile = arguments[3]
        self.connectionID = connectionID
    }

    func run() -> LocalAPIError? {
        do {
            switch action {
            case .store:
                try LocalAPICredentialKeychain.store(
                    try readCredential(),
                    profile: profile,
                    connectionID: connectionID
                )
            case .delete:
                try LocalAPICredentialKeychain.delete(profile: profile, connectionID: connectionID)
            }
            return nil
        } catch {
            return .credentialUnavailable
        }
    }

    private func readCredential() throws -> Data {
        var credential = Data()
        while credential.count <= LocalAPICredential.byteCount {
            guard
                let chunk = try FileHandle.standardInput.read(
                    upToCount: LocalAPICredential.byteCount + 1 - credential.count
                ), !chunk.isEmpty
            else { break }
            credential.append(chunk)
        }
        guard credential.count == LocalAPICredential.byteCount else {
            throw LocalAPICredentialKeychainError.invalidCredential
        }
        return credential
    }
}
