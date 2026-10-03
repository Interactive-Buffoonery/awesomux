#!/usr/bin/env bash
# Real subprocess check: bounded collection must keep draining and reject partial results.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-output-limit.XXXXXX")"
trap 'rm -rf -- "$CHECK_DIR"' EXIT
# Failure modes: overflow on the first mutation must allow recovery; read-only
# overflow must still reject partial data. Exercise the actual provider mappers.
python3 - "$ROOT_DIR" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
services = Path(sys.argv[1]) / "Sources/awesoMux/Services"
methods = []
for provider in ("Claude", "Codex", "Grok"):
    source = (services / f"ProcessAgentPluginRunner+{provider}.swift").read_text()
    start = source.index(f"    private func {provider.lower()}MutationFailure(")
    end = source.index("\n    }", start) + len("\n    }")
    methods.append(source[start:end].replace("private func", "func", 1))
(Path(sys.argv[2]) / "mappers.swift").write_text("import Foundation\nstruct Mappers {\n" + "\n".join(methods) + "\n}")
PY
cat > "$CHECK_DIR/check.swift" <<'SWIFT'
import Foundation

@main struct OutputCapCheck {
    static func main() async throws {
        let cap = 512 * 1024
        precondition(CommandRunnerError.outputTruncated("/bin/sh", cap).errorDescription?.isEmpty == false)
        let overflow = CommandRunnerError.outputTruncated("/bin/sh", cap)
        for status in [Mappers().claudeMutationFailure(overflow, executable: "/bin/sh"), Mappers().codexMutationFailure(overflow, executable: "/bin/sh"), Mappers().grokMutationFailure(overflow, executable: "/bin/sh")] {
            precondition(status.allowsRepair && status.allowsUninstall, "first mutation overflow stranded recovery")
        }
        func run(_ script: String, timeout: Duration = .seconds(10)) async throws -> CommandResult {
            try await ProcessCommandRunner(timeout: timeout).run(executable: "/bin/sh", args: ["-c", script], env: [:], cwd: nil)
        }
        let exact = try await run("/usr/bin/head -c \(cap) /dev/zero")
        precondition(exact.stdout.utf8.count == cap && exact.isSuccess)
        for script in [
            "/usr/bin/head -c \(cap + 1) /dev/zero",
            "/usr/bin/head -c \(cap * 8) /dev/zero >&2",
            "printf '[]'; /usr/bin/head -c \(cap * 8) /dev/zero; /usr/bin/head -c \(cap * 8) /dev/zero >&2"
        ] {
            do { _ = try await run(script); fatalError("overflow returned a partial result") }
            catch CommandRunnerError.outputTruncated(_, let limit) { precondition(limit == cap) }
        }
        do { _ = try await run("/usr/bin/head -c \(cap * 2) /dev/zero; /bin/sleep 5", timeout: .milliseconds(100)); fatalError("timeout returned") }
        catch CommandRunnerError.timedOut { }
        let task = Task { try await run("/usr/bin/head -c \(cap * 2) /dev/zero; /bin/sleep 5") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; fatalError("cancellation returned") }
        catch is CancellationError { }
        print("PASS exact cap; stdout/stderr overflow; valid JSON prefix rejected; timeout/cancellation precedence")
    }
}
SWIFT
swiftc -parse-as-library \
  "$ROOT_DIR/Sources/awesoMux/Services/CommandRunner.swift" \
  "$ROOT_DIR/Sources/awesoMux/Services/ProcessCommandRunner.swift" \
  "$ROOT_DIR/Sources/awesoMux/Services/AgentPluginStatus.swift" \
  "$ROOT_DIR/Sources/awesoMux/Services/AgentPluginDiagnostics.swift" \
  "$CHECK_DIR/mappers.swift" \
  "$CHECK_DIR/check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
