import Foundation

public struct GitWorktreeParseDiagnostic: Equatable, Sendable {
    public var recordIndex: Int
    public var message: String

    public init(recordIndex: Int, message: String) {
        self.recordIndex = recordIndex
        self.message = message
    }
}

public struct GitWorktreeParseResult: Equatable, Sendable {
    public var records: [GitWorktreeRecord]
    public var diagnostics: [GitWorktreeParseDiagnostic]

    public init(records: [GitWorktreeRecord], diagnostics: [GitWorktreeParseDiagnostic]) {
        self.records = records
        self.diagnostics = diagnostics
    }
}

public struct GitWorktreePorcelainParser: Sendable {
    public init() {}

    public func parse(_ data: Data) -> GitWorktreeParseResult {
        guard !data.isEmpty else {
            return GitWorktreeParseResult(records: [], diagnostics: [])
        }

        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var records: [GitWorktreeRecord] = []
        var diagnostics: [GitWorktreeParseDiagnostic] = []
        var recordFields: [Data.SubSequence] = []
        var recordIndex = 0

        for field in fields.dropLast() {
            if field.isEmpty {
                appendRecord(
                    from: recordFields,
                    recordIndex: recordIndex,
                    to: &records,
                    diagnostics: &diagnostics
                )
                recordFields.removeAll(keepingCapacity: true)
                recordIndex += 1
            } else {
                recordFields.append(field)
            }
        }

        if data.last != 0 || !recordFields.isEmpty || fields.last?.isEmpty == false {
            diagnostics.append(
                GitWorktreeParseDiagnostic(
                    recordIndex: recordIndex,
                    message: "Record is not terminated by an empty NUL field"
                ))
        }

        return GitWorktreeParseResult(records: records, diagnostics: diagnostics)
    }

    private func appendRecord(
        from fields: [Data.SubSequence],
        recordIndex: Int,
        to records: inout [GitWorktreeRecord],
        diagnostics: inout [GitWorktreeParseDiagnostic]
    ) {
        guard !fields.isEmpty else { return }

        var decoded: [String] = []
        for field in fields {
            guard let string = String(data: Data(field), encoding: .utf8) else {
                diagnostics.append(
                    GitWorktreeParseDiagnostic(
                        recordIndex: recordIndex,
                        message: "Record contains invalid UTF-8"
                    ))
                return
            }
            decoded.append(string)
        }

        do {
            let record = try parseRecord(decoded, isMainWorktree: recordIndex == 0)
            records.append(record)
        } catch let error as RecordError {
            diagnostics.append(
                GitWorktreeParseDiagnostic(
                    recordIndex: recordIndex,
                    message: error.message
                ))
        } catch {
            diagnostics.append(
                GitWorktreeParseDiagnostic(
                    recordIndex: recordIndex,
                    message: "Malformed worktree record"
                ))
        }
    }

    private func parseRecord(_ fields: [String], isMainWorktree: Bool) throws -> GitWorktreeRecord {
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        var locked: String?
        var prunable: String?

        for field in fields {
            let (key, value) = splitField(field)
            switch key {
            case "worktree":
                guard path == nil, let value, !value.isEmpty else {
                    throw RecordError("Record has a missing or duplicate worktree path")
                }
                path = value
            case "HEAD":
                guard head == nil, let value, !value.isEmpty else {
                    throw RecordError("Record has a missing or duplicate HEAD object ID")
                }
                head = value
            case "branch":
                guard branch == nil, let value, !value.isEmpty else {
                    throw RecordError("Record has a missing or duplicate branch ref")
                }
                branch = value
            case "detached":
                detached = true
            case "bare":
                bare = true
            case "locked":
                locked = value ?? ""
            case "prunable":
                prunable = value ?? ""
            default:
                continue
            }
        }

        guard let path else {
            throw RecordError("Record is missing its worktree path")
        }
        guard !(detached && branch != nil) else {
            throw RecordError("Record cannot be both detached and on a branch")
        }
        guard bare || detached || branch != nil else {
            throw RecordError("Record has no branch, detached, or bare state")
        }

        let canonicalPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return GitWorktreeRecord(
            canonicalPath: canonicalPath,
            headObjectID: head,
            branchRef: branch,
            isDetached: detached,
            displayBranch: displayBranch(branch: branch, detached: detached, bare: bare),
            isMainWorktree: isMainWorktree,
            isBare: bare,
            lockReason: locked,
            prunableReason: prunable
        )
    }

    private func splitField(_ field: String) -> (String, String?) {
        guard let separator = field.firstIndex(of: " ") else {
            return (field, nil)
        }
        return (String(field[..<separator]), String(field[field.index(after: separator)...]))
    }

    private func displayBranch(branch: String?, detached: Bool, bare: Bool) -> String {
        let raw: String
        if let branch {
            raw = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        } else if detached {
            raw = "detached HEAD"
        } else if bare {
            raw = "bare"
        } else {
            raw = ""
        }
        return String(
            raw.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? Character("�") : Character($0)
            })
    }
}

private struct RecordError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
