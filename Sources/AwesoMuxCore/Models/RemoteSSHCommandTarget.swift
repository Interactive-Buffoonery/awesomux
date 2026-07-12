import Foundation

public enum RemoteSSHCommandTarget {
    public static func parseSubmittedCommand(_ command: String) -> String? {
        var tokens = tokenize(command)
        guard tokens.first == "ssh" else {
            return nil
        }
        tokens.removeFirst()

        var index = 0
        var login: String?
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else {
                break
            }

            // `-l` names the login user, but the destination host is still a
            // later positional token — record the login and keep scanning rather
            // than assuming the host sits exactly two tokens on, which mis-parses
            // ordinary forms like `ssh -l alice -p 2222 host` as `alice@-p`.
            if token == "-l", index + 1 < tokens.count {
                login = tokens[index + 1]
                index += 2
                continue
            }
            if optionsTakingValues.contains(token) {
                index += 2
            } else {
                index += 1
            }
        }

        guard index < tokens.count else {
            return nil
        }
        let target = tokens[index]
        guard !target.isEmpty, !target.hasPrefix("-") else {
            return nil
        }
        // OpenSSH lets an explicit `-l` login win over any `user@` in the
        // positional destination (`ssh -l u alice@host` connects as `u`), so when
        // a login is present it replaces the user and we keep only the host part.
        if let login {
            let host = target.split(separator: "@").last.map(String.init) ?? target
            return "\(login)@\(host)"
        }
        return target
    }

    private static let optionsTakingValues: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
        "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
    ]

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if quote != nil {
                if character == quote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
