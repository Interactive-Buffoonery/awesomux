import Foundation

public enum RemoteSSHCommandTarget {
    public static func parseManagedWorkspaceOffer(_ command: String) -> String? {
        let tokens = tokenize(command)
        guard tokens.count == 2,
            tokens[0] == "ssh",
            let target = RemoteTarget(parsing: tokens[1]),
            target.isSafeSSHDestination
        else {
            return nil
        }
        return target.sshDestination
    }

    public static func isSSHCommand(_ command: String) -> Bool {
        var tokens = tokenize(command)
        guard tokens.first == "ssh" else {
            return false
        }
        tokens.removeFirst()

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else {
                break
            }

            if optionsTakingValues.contains(token) {
                index += 2
            } else {
                index += 1
            }
        }

        guard index < tokens.count else {
            return false
        }
        let target = tokens[index]
        return !target.isEmpty && !target.hasPrefix("-")
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
