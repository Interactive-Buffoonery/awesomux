import AwesoMuxTestSupport
import Foundation
import Testing

@Suite("Build and run script")
struct BuildAndRunScriptTests {
    @Test("AMX staging rejects stale artifacts after failed builds")
    func amxStagingRequiresSuccessfulBuild() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")
        let buildStart = try #require(script.range(of: "# Let Zig track SDK"))
        let buildEnd = try #require(
            script.range(of: "\nif [[ ! -f \"$GHOSTTY_SHARE/terminfo", range: buildStart.upperBound..<script.endIndex))
        let stageStart = try #require(script.range(of: "# Stage amx only"))
        let stageEnd = try #require(script.range(of: "\ncp -R \"$GHOSTTY_SHARE/", range: stageStart.upperBound..<script.endIndex))
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-amx-staging")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let root = temporaryDirectory.url
        try FileManager.default.createDirectory(at: root.appendingPathComponent("script"), withIntermediateDirectories: true)
        let builder = root.appendingPathComponent("script/build_amx.sh")
        try Data("#!/bin/bash\nexit \"$BUILD_STATUS\"\n".utf8).write(to: builder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: builder.path)
        let artifact = root.appendingPathComponent("amx")
        try Data("old-artifact".utf8).write(to: artifact)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: artifact.path)

        for (buildStatus, required) in [(1, false), (1, true), (0, false), (0, true)] {
            let staged = root.appendingPathComponent("staged-\(buildStatus)-\(required)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                """
                set -euo pipefail
                mode_requires_amx() { \(required ? "true" : "false"); }
                amx_install_error() { echo "$*" >&2; }
                \(script[buildStart.lowerBound..<buildEnd.lowerBound])
                \(script[stageStart.lowerBound..<stageEnd.lowerBound])
                """,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["ROOT_DIR"] = root.path
            environment["AMX_BUILT_BINARY"] = artifact.path
            environment["AMX_BINARY"] = staged.path
            environment["BUILD_STATUS"] = String(buildStatus)
            process.environment = environment
            let captured = try captureOutput(of: process)
            #expect(process.terminationStatus == (buildStatus != 0 && required ? 1 : 0), "\(captured.stderr)")
            #expect(FileManager.default.fileExists(atPath: staged.path) == (buildStatus == 0))
            #expect(FileManager.default.isExecutableFile(atPath: artifact.path))
            if buildStatus != 0 {
                #expect(captured.stderr.contains("amx build failed"))
            }
        }
    }

    @Test("candidate pid enumeration finds a name-matching ancestor process")
    func candidatePIDEnumerationFindsAncestorProcess() throws {
        // `pgrep -x` silently excludes the pgrep process's own ancestors, so a
        // running awesoMux instance hosting the very pane this script runs in
        // never showed up as a candidate (awesomux#281). Reproduce that exact
        // shape for real: a helper process that forks a child bash (instead of
        // exec'ing over itself) stays alive under a controlled name while its
        // child calls the function under test, making the helper a genuine
        // process-tree ancestor of that call — not just a same-name process.
        let result = try Self.runCandidatePIDAncestorSnippet()

        #expect(result.exitStatus == 0, "stderr: \(result.error)")
        #expect(result.output.contains("ancestor_found=yes"), "stdout: \(result.output)")
    }

    @Test("candidate pid enumeration fails closed when ps itself fails")
    func candidatePIDEnumerationFailsClosedOnPSFailure() throws {
        // The rewrite moved the ps-failure handling inline; nothing else in
        // this suite drives `ps` itself failing (the other enumeration-failure
        // tests stub `app_bundle_pids`/`app_bundle_is_running` a layer up), so
        // this is the only test that would catch a regression in that branch.
        let result = try Self.runCandidatePIDsPSFailureSnippet()

        #expect(result.exitStatus == 70, "stderr: \(result.error)")
        #expect(result.error.contains("unable to enumerate running awesoMux processes (ps exited"))
    }

    enum AncestryProtectionCase: String, CaseIterable {
        case terminateAppBundleRefusesSelfTermination
        case terminateAppBundleKillsNonAncestorTarget
        case terminateAppBundleRefusesWhenAncestryInspectionFails
    }

    @Test(arguments: AncestryProtectionCase.allCases)
    func ancestryProtection(_ scenario: AncestryProtectionCase) throws {
        switch scenario {
        case .terminateAppBundleRefusesSelfTermination:
            // Fixing the ancestor-detection bug above means an ancestor awesoMux
            // instance now correctly shows up as a termination candidate — but a
            // non-command-bridged pane (the default; ADR-0011) has awesoMux
            // itself holding the pane's PTY, so terminating an ancestor SIGHUPs
            // this very script before it can relaunch anything. `$PPID` inside
            // the spawned `bash -c` is genuinely this test process's pid, so
            // `app_bundle_pids` returning it is a real ancestor relationship, not
            // a stubbed one.
            let result = try Self.runSelfTerminationGuardSnippet(targetIsAncestor: true)

            #expect(result.exitStatus == 71, "stderr: \(result.error)")
            #expect(result.error.contains("refusing to terminate"))
            // Absence is meaningful here despite `captureOutput` being able to
            // return truncated output: the child is a single `bash -c` that
            // backgrounds nothing, so no grandchild can still be writing when it
            // exits, and the sibling test below drives this same helper with
            // `targetIsAncestor: false` and asserts this exact marker IS present —
            // proving the marker reaches the capture when the guard does not fire.
            #expect(!result.output.contains("kill_called=yes"))
        case .terminateAppBundleKillsNonAncestorTarget:
            let result = try Self.runSelfTerminationGuardSnippet(targetIsAncestor: false)

            #expect(result.exitStatus == 0, "stderr: \(result.error)")
            #expect(result.output.contains("kill_called=yes"), "stdout: \(result.output)")
        case .terminateAppBundleRefusesWhenAncestryInspectionFails:
            // A guard whose entire job is refusing an unsafe kill must not fail
            // open: if `ps` can't be consulted mid-walk, that must not silently
            // resolve to "not an ancestor, safe to kill" (found by code review —
            // the walk originally treated a failed/empty ppid lookup exactly
            // like reaching pid 1 with no match).
            let result = try Self.runSelfTerminationGuardAncestryFailureSnippet()

            #expect(result.exitStatus == 70, "stderr: \(result.error)")
            // Same reasoning as the self-termination test above: one `bash -c`
            // child, nothing backgrounded, and `terminateAppBundleKillsNonAncestorTarget`
            // proves this marker survives the capture when `kill` is actually reached.
            #expect(!result.output.contains("kill_called=yes"), "stdout: \(result.output)")
        }
    }

    @Test("install keeps an in-use replaced bundle named awesoMux")
    func installKeepsInUseReplacedBundleNamedAwesoMux() throws {
        let result = try Self.runInstallReplacementSnippet()

        #expect(result.exitStatus == 0, "stderr: \(result.error)")
        #expect(result.output.contains("installed=new"), "stdout: \(result.output)")
        #expect(result.output.contains("retired=old"), "stdout: \(result.output)")
        #expect(result.output.contains("retired_name=awesoMux.app"), "stdout: \(result.output)")
        #expect(result.output.contains("trash_called=no"), "stdout: \(result.output)")
    }

    @Test("install cleans retired bundles after their sessions exit")
    func installCleansUnusedRetiredBundles() throws {
        let result = try Self.runRetiredBundleCleanupSnippet()

        #expect(result.exitStatus == 0, "stderr: \(result.error)")
        #expect(result.output.contains("used=kept"), "stdout: \(result.output)")
        #expect(result.output.contains("unused=cleaned"), "stdout: \(result.output)")
        #expect(result.output.contains("trashed=unused"), "stdout: \(result.output)")
    }

    @Test("open files count as in use when lsof also reports a partial scan")
    func openFilesCountAsInUseWhenLSOFExitsOne() throws {
        let result = try Self.runPartialLSOFResultSnippet()

        #expect(result.exitStatus == 0, "stderr: \(result.error)")
        #expect(result.output.contains("in_use=yes"), "stdout: \(result.output)")
    }

    enum AppTerminationCase: String, CaseIterable {
        case terminateAppBundleAndWaitReturnsOnceExited
        case terminateAppBundleAndWaitEscalatesToKill
        case terminateAppBundleAndWaitFailsWhenKillIgnored
        case terminateAppBundleAndWaitPropagatesEnumerationFailureWithoutEscalating
    }

    @Test(arguments: AppTerminationCase.allCases)
    func appTermination(_ scenario: AppTerminationCase) throws {
        switch scenario {
        case .terminateAppBundleAndWaitReturnsOnceExited:
            // app_bundle_is_running: 0 = still running, 1 = exited.
            let result = try Self.runTerminationSnippet(
                appRunningStatuses: [0, 0, 1],
                command: """
                    set +e
                    terminate_app_bundle_and_wait /tmp/fake.app
                    status=$?
                    printf 'status=%s signals=%s\\n' "$status" "$TERMINATE_SIGNALS"
                    exit "$status"
                    """
            )

            #expect(result.exitStatus == 0)
            #expect(result.output.contains("status=0 signals=TERM"))
        case .terminateAppBundleAndWaitEscalatesToKill:
            // Still running through the entire graceful wait (20 polls + 1 final
            // resample), then exits on the first poll after SIGKILL.
            let result = try Self.runTerminationSnippet(
                appRunningStatuses: Array(repeating: Int32(0), count: 21) + [1],
                command: """
                    set +e
                    terminate_app_bundle_and_wait /tmp/fake.app
                    status=$?
                    printf 'status=%s signals=%s\\n' "$status" "$TERMINATE_SIGNALS"
                    exit "$status"
                    """
            )

            #expect(result.exitStatus == 0)
            #expect(result.output.contains("status=0 signals=TERM,KILL"))
        case .terminateAppBundleAndWaitFailsWhenKillIgnored:
            // Still running through both the graceful wait (21 calls) and the
            // post-KILL wait (8 polls + 1 final resample = 9 calls).
            let result = try Self.runTerminationSnippet(
                appRunningStatuses: Array(repeating: Int32(0), count: 30),
                command: """
                    set +e
                    terminate_app_bundle_and_wait /tmp/fake.app
                    status=$?
                    printf 'status=%s signals=%s\\n' "$status" "$TERMINATE_SIGNALS"
                    exit "$status"
                    """
            )

            #expect(result.exitStatus == 3)
            #expect(result.output.contains("status=3 signals=TERM,KILL"))
        case .terminateAppBundleAndWaitPropagatesEnumerationFailureWithoutEscalating:
            let result = try Self.runTerminationSnippet(
                appRunningStatuses: [70],
                command: """
                    set +e
                    terminate_app_bundle_and_wait /tmp/fake.app
                    status=$?
                    printf 'status=%s signals=%s\\n' "$status" "$TERMINATE_SIGNALS"
                    exit "$status"
                    """
            )

            #expect(result.exitStatus == 70)
            // Only the initial TERM should fire — an enumeration failure is not
            // "the process ignored SIGTERM," so it must not escalate to KILL.
            #expect(result.output.contains("status=70 signals=TERM"))
        }
    }

    /// Scoped to `install_app()`'s own body (up to the `case "$MODE" in`
    /// dispatch that follows it) — a search bounded only by `script.endIndex`
    /// would still match `--perf-install`'s later call to the same helper and
    /// couldn't tell a regression in `install_app()` itself from one there.

    private static func contents(of relativePath: String) throws -> String {
        let root = try packageRootURL()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func packageRootURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = root.appendingPathComponent("Package.swift")
        try #require(
            FileManager.default.fileExists(atPath: manifest.path),
            "Package.swift not found at \(manifest.path); the test file likely moved depth"
        )
        return root
    }

    private static func installReplacementFunctions(from script: String) throws -> String {
        let retirementStart = try #require(script.range(of: "retired_app_bundle_is_in_use() {")?.lowerBound)
        let appExecutable = try #require(
            script.range(of: "\napp_executable_path() {", range: retirementStart..<script.endIndex)?.lowerBound)
        let installBody = try installAppBody(from: script)
        return String(script[retirementStart..<appExecutable]) + "\n" + installBody
    }

    private static func runInstallReplacementSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try installReplacementFunctions(from: script)
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-install-replacement")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let bash = """
            set -euo pipefail
            APP_NAME=awesoMux
            INSTALL_DIR="\(temporaryDirectory.url.path)/Applications"
            INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
            APP_BUNDLE="\(temporaryDirectory.url.path)/staged/$APP_NAME.app"
            RETIRED_APP_BUNDLES="$INSTALL_DIR/.awesomux-retired"
            mkdir -p "$INSTALLED_APP_BUNDLE" "$APP_BUNDLE"
            printf old > "$INSTALLED_APP_BUNDLE/version"
            printf new > "$APP_BUNDLE/version"

            \(functions)

            terminate_app_bundle_and_wait() { :; }
            retired_app_bundle_is_in_use() { return 0; }
            TRASH_CALLED=no
            trash_path() { TRASH_CALLED=yes; }

            install_app

            retired_bundle="$(find "$RETIRED_APP_BUNDLES" -type d -name "$APP_NAME.app" -print -quit)"
            printf 'installed=%s\n' "$(<"$INSTALLED_APP_BUNDLE/version")"
            printf 'retired=%s\n' "$(<"$retired_bundle/version")"
            printf 'retired_name=%s\n' "${retired_bundle##*/}"
            printf 'trash_called=%s\n' "$TRASH_CALLED"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private static func runRetiredBundleCleanupSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try installReplacementFunctions(from: script)
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-retired-cleanup")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let bash = """
            set -euo pipefail
            APP_NAME=awesoMux
            INSTALL_DIR="\(temporaryDirectory.url.path)/Applications"
            INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
            APP_BUNDLE="\(temporaryDirectory.url.path)/staged/$APP_NAME.app"
            RETIRED_APP_BUNDLES="$INSTALL_DIR/.awesomux-retired"
            mkdir -p \
              "$INSTALLED_APP_BUNDLE" \
              "$APP_BUNDLE" \
              "$RETIRED_APP_BUNDLES/used/$APP_NAME.app" \
              "$RETIRED_APP_BUNDLES/unused/$APP_NAME.app"

            \(functions)

            terminate_app_bundle_and_wait() { :; }
            retired_app_bundle_is_in_use() {
              [[ "$1" == "$INSTALLED_APP_BUNDLE" || "$1" == "$RETIRED_APP_BUNDLES/used/$APP_NAME.app" ]]
            }
            TRASHED=""
            trash_path() {
              TRASHED="${TRASHED:+$TRASHED,}${1##*/}"
              /bin/mv "$1" "\(temporaryDirectory.url.path)/trashed-${1##*/}"
            }

            install_app

            [[ -d "$RETIRED_APP_BUNDLES/used/$APP_NAME.app" ]] && used=kept || used=missing
            [[ -d "$RETIRED_APP_BUNDLES/unused" ]] && unused=kept || unused=cleaned
            printf 'used=%s\n' "$used"
            printf 'unused=%s\n' "$unused"
            printf 'trashed=%s\n' "$TRASHED"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private static func runPartialLSOFResultSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try installReplacementFunctions(from: script)
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-partial-lsof")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let fakeLSOF = temporaryDirectory.url.appendingPathComponent("lsof")
        try "#!/bin/bash\nprintf '29243\\n29252\\n'\nexit 1\n".write(
            to: fakeLSOF,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeLSOF.path)

        let bash = """
            set -euo pipefail
            APP_NAME=awesoMux
            AMX_NAME=amx
            PROCESS_ENUMERATION_FAILURE=70
            LSOF_BIN="\(fakeLSOF.path)"
            RETIRED_APP_BUNDLES="\(temporaryDirectory.url.path)/retired"

            \(functions)

            if retired_app_bundle_is_in_use /tmp/fake.app; then
              printf 'in_use=yes\n'
            else
              printf 'in_use=no status=%s\n' "$?"
              exit 1
            fi
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private static func processStateFunctions(from script: String) throws -> String {
        let start = try #require(script.range(of: "app_bundle_in_state() {")?.lowerBound)
        let end = try #require(script.range(of: "\nwait_for_app_bundle() {", range: start..<script.endIndex)?.lowerBound)
        return String(script[start..<end])
    }

    private static func pidResolutionFunctions(from script: String) throws -> String {
        let start = try #require(script.range(of: "single_app_bundle_pid() {")?.lowerBound)
        let end = try #require(
            script.range(
                of: "\nvalidate_perf_sample_interval() {",
                range: start..<script.endIndex
            )?.lowerBound)
        return String(script[start..<end])
    }

    private static func candidatePIDsFunction(from script: String) throws -> String {
        let start = try #require(script.range(of: "awesomux_candidate_pids() {")?.lowerBound)
        let end = try #require(script.range(of: "\n\n# PIDs whose actual executable", range: start..<script.endIndex)?.lowerBound)
        return String(script[start..<end])
    }

    /// Compiles a tiny helper that forks a child instead of exec'ing over
    /// itself, then waits for it — so the helper process survives under its
    /// own compiled-name `comm` while its child (and that child's own `bash
    /// -c` grandchild, which calls `awesomux_candidate_pids`) runs beneath
    /// it. That makes the helper a real process-tree ancestor of the
    /// enumeration call, the exact shape pgrep -x silently excludes.
    private static func runCandidatePIDAncestorSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let function = try candidatePIDsFunction(from: script)

        let tempDir = try TemporaryDirectory()
        // `tempDir` has no further direct reference after deriving these two
        // URLs, so ARC is free to run its deinit (which deletes the
        // directory) before the compile/exec steps below finish with it —
        // the same bug already fixed at its other call sites in
        // GhosttyConfigEnvironmentTests.swift and HelperConnectionTests.swift.
        defer { withExtendedLifetime(tempDir) {} }
        let helperName = "amxpidtest"
        let sourceURL = tempDir.url.appendingPathComponent("\(helperName).c")
        let helperURL = tempDir.url.appendingPathComponent(helperName)

        let source = """
            #include <unistd.h>
            #include <sys/wait.h>
            int main(int argc, char **argv) {
                pid_t pid = fork();
                if (pid == 0) {
                    execvp(argv[1], &argv[1]);
                    _exit(127);
                }
                int status = 0;
                waitpid(pid, &status, 0);
                return WEXITSTATUS(status);
            }
            """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-O0", "-o", helperURL.path, sourceURL.path]
        try compile.run()
        try compile.waitUntilExitEventually()
        try #require(compile.terminationStatus == 0, "clang failed to compile the ancestor-process test helper")

        let bash = """
            set -euo pipefail
            parent_pid="$PPID"
            APP_NAME=\(helperName)
            PROCESS_ENUMERATION_FAILURE=70
            \(function)

            candidates="$(awesomux_candidate_pids)"
            ancestor_found=no
            for pid in $candidates; do
              [[ "$pid" == "$parent_pid" ]] && ancestor_found=yes
            done
            printf 'parent_pid=%s ancestor_found=%s candidates=[%s]\\n' "$parent_pid" "$ancestor_found" "$candidates"
            """

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["/bin/bash", "-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private static func runCandidatePIDsPSFailureSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let function = try candidatePIDsFunction(from: script)

        let bash = """
            set -euo pipefail
            APP_NAME=awesoMux
            PROCESS_ENUMERATION_FAILURE=70
            \(function)

            ps() { echo "ps: permission denied" >&2; return 1; }
            awesomux_candidate_pids
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private static func selfTerminationGuardFunctions(from script: String) throws -> String {
        let start = try #require(script.range(of: "script_runs_inside_pid() {")?.lowerBound)
        let end = try #require(script.range(of: "\napp_bundle_is_running() {", range: start..<script.endIndex)?.lowerBound)
        return String(script[start..<end])
    }

    /// `app_bundle_pids` is stubbed to hand back either `$PPID` (this test
    /// process's real pid — a genuine ancestor of the spawned `bash -c`, not
    /// a synthetic one) or an unrelated pid, so the same real
    /// `terminate_app_bundle` body decides whether to refuse. `kill` is
    /// stubbed rather than actually invoked — this test only needs to know
    /// whether it was reached, not to signal anything.
    private static func runSelfTerminationGuardSnippet(targetIsAncestor: Bool) throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try selfTerminationGuardFunctions(from: script)
        let targetPID = targetIsAncestor ? "$PPID" : "999999"

        let bash = """
            set -euo pipefail
            PROCESS_ENUMERATION_FAILURE=70
            SELF_TERMINATION_REFUSED=71
            \(functions)

            app_bundle_pids() { echo \(targetPID); }
            kill() { KILL_CALLED=yes; return 0; }

            terminate_app_bundle /tmp/fake.app
            printf 'kill_called=%s\\n' "${KILL_CALLED:-no}"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    /// `ps` is stubbed to fail outright, simulating the ancestry walk losing
    /// its ability to inspect a pid mid-walk (a reaped intermediate process,
    /// a transient `ps` failure). The target pid is unrelated to `$PPID` —
    /// the point is that the walk can never determine there ISN'T a match
    /// further up, so it must refuse rather than fall through to "safe."
    private static func runSelfTerminationGuardAncestryFailureSnippet() throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try selfTerminationGuardFunctions(from: script)

        let bash = """
            set -euo pipefail
            PROCESS_ENUMERATION_FAILURE=70
            SELF_TERMINATION_REFUSED=71
            \(functions)

            app_bundle_pids() { echo 999999; }
            ps() { return 1; }
            kill() { KILL_CALLED=yes; return 0; }

            terminate_app_bundle /tmp/fake.app
            printf 'kill_called=%s\\n' "${KILL_CALLED:-no}"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]
        let captured = try captureOutput(of: process)

        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    /// `app_bundle_in_state` through `terminate_app_bundle_and_wait`'s closing
    /// brace — everything `terminate_app_bundle_and_wait` needs, so it can run
    /// for real against a stubbed `app_bundle_is_running`/`terminate_app_bundle`
    /// instead of only being checked for literal text.
    private static func terminationHelperFunctions(from script: String) throws -> String {
        let start = try #require(script.range(of: "app_bundle_in_state() {")?.lowerBound)
        let functionStart = try #require(script.range(of: "\nterminate_app_bundle_and_wait() {", range: start..<script.endIndex))
        let closingBrace = try #require(script.range(of: "\n}", range: functionStart.upperBound..<script.endIndex))
        return String(script[start..<closingBrace.upperBound])
    }

    private static func runTerminationSnippet(appRunningStatuses: [Int32], command: String) throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try terminationHelperFunctions(from: script)
        let statuses = appRunningStatuses.map(String.init).joined(separator: " ")
        let bash = """
            set -euo pipefail
            \(functions)

            APP_RUNNING_CALLS=0
            APP_RUNNING_STATUSES=(\(statuses))
            APP_RUNNING_DEFAULT_STATUS=0

            app_bundle_is_running() {
              APP_RUNNING_CALLS=$((APP_RUNNING_CALLS + 1))
              local index=$((APP_RUNNING_CALLS - 1))
              local status="${APP_RUNNING_STATUSES[$index]:-$APP_RUNNING_DEFAULT_STATUS}"
              return "$status"
            }

            TERMINATE_SIGNALS=""
            terminate_app_bundle() {
              local signal="${2:-TERM}"
              TERMINATE_SIGNALS="${TERMINATE_SIGNALS:+$TERMINATE_SIGNALS,}$signal"
            }

            sleep() { :; }

            \(command)
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", bash]

        let captured = try captureOutput(of: process)
        return ShellResult(
            exitStatus: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private struct ShellResult {
        let exitStatus: Int32
        let output: String
        let error: String
    }
    private static func installAppBody(from script: String) throws -> Substring {
        let installFunction = try #require(script.range(of: "install_app() {"))
        let dispatch = try #require(script.range(of: "\ncase \"$MODE\" in", range: installFunction.upperBound..<script.endIndex))
        return script[installFunction.lowerBound..<dispatch.lowerBound]
    }

}
