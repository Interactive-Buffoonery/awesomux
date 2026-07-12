import AwesoMuxCore
import Darwin
import Foundation

enum AgentHookHealthCheck {
    static let protocolEnvironmentKey = AgentRuntimeEnvironmentKey.eventProtocol
    static let sessionEnvironmentKey = AgentRuntimeEnvironmentKey.sessionID
    static let paneEnvironmentKey = AgentRuntimeEnvironmentKey.paneID
    static let eventFileEnvironmentKey = AgentRuntimeEnvironmentKey.eventFile

    struct FileInfo: Equatable {
        var exists: Bool
        var isRegularFile: Bool
        var ownerUID: uid_t
        var canOpenForAppend: Bool
    }

    struct Result: Equatable {
        var exitCode: Int
        var message: String

        static let success = Result(
            exitCode: 0,
            message: "awesoMux agent runtime health check OK: event file is writable; this does not confirm the app consumed an event."
        )
    }

    static func run(
        environment: [String: String],
        output: (String) -> Void,
        errorOutput: (String) -> Void
    ) -> Int {
        let result = diagnose(environment: environment)
        if result.exitCode == 0 {
            output(result.message)
        } else {
            errorOutput(result.message)
        }
        return result.exitCode
    }

    static func diagnose(
        environment: [String: String],
        effectiveUID: uid_t = geteuid(),
        fileInfoProvider: (String) -> FileInfo? = fileInfo(at:)
    ) -> Result {
        let requiredKeys = AgentRuntimeEnvironmentKey.healthCheckRequiredKeys
        let missingKeys = requiredKeys.filter { key in
            (environment[key] ?? "").isEmpty
        }
        guard missingKeys.isEmpty else {
            return failure(
                code: 10,
                "missing environment: \(missingKeys.joined(separator: ", "))"
            )
        }

        let actualProtocol = environment[protocolEnvironmentKey] ?? ""
        guard actualProtocol == AgentRuntimeEvent.protocolName else {
            return failure(
                code: 20,
                "bad protocol: \(actualProtocol); expected \(AgentRuntimeEvent.protocolName)"
            )
        }

        guard UUID(uuidString: environment[sessionEnvironmentKey] ?? "") != nil else {
            return failure(
                code: 30,
                "invalid UUID: \(sessionEnvironmentKey)=\(environment[sessionEnvironmentKey] ?? "")"
            )
        }
        guard let paneID = UUID(uuidString: environment[paneEnvironmentKey] ?? "") else {
            return failure(
                code: 31,
                "invalid UUID: \(paneEnvironmentKey)=\(environment[paneEnvironmentKey] ?? "")"
            )
        }

        let eventFilePath = environment[eventFileEnvironmentKey] ?? ""
        let eventFileURL = URL(fileURLWithPath: eventFilePath)
        let expectedFileName = "\(paneID.uuidString).jsonl"
        guard eventFileURL.lastPathComponent == expectedFileName else {
            return failure(
                code: 40,
                "stale pane/file mismatch: \(paneEnvironmentKey)=\(paneID.uuidString) but event file is \(eventFileURL.lastPathComponent)"
            )
        }

        guard let fileInfo = fileInfoProvider(eventFilePath), fileInfo.exists else {
            return failure(code: 50, "missing event file: \(eventFilePath)")
        }
        guard fileInfo.isRegularFile else {
            return failure(code: 51, "non-regular event file: \(eventFilePath)")
        }
        guard fileInfo.ownerUID == effectiveUID else {
            return failure(
                code: 52,
                "wrong owner for event file: \(eventFilePath) owner=\(fileInfo.ownerUID) expected=\(effectiveUID)"
            )
        }
        guard fileInfo.canOpenForAppend else {
            return failure(code: 53, "non-writable event file: \(eventFilePath)")
        }

        return .success
    }

    private static func failure(code: Int, _ reason: String) -> Result {
        Result(
            exitCode: code,
            message: "awesoMux agent runtime health check failed: \(reason)"
        )
    }

    private static func fileInfo(at path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return FileInfo(
                exists: false,
                isRegularFile: false,
                ownerUID: geteuid(),
                canOpenForAppend: false
            )
        }

        let isRegularFile = (st.st_mode & S_IFMT) == S_IFREG
        var canOpenForAppend = false
        if isRegularFile {
            let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                canOpenForAppend = true
                close(fd)
            }
        }

        return FileInfo(
            exists: true,
            isRegularFile: isRegularFile,
            ownerUID: st.st_uid,
            canOpenForAppend: canOpenForAppend
        )
    }
}
