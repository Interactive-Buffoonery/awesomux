import AwesoMuxTestSupport
import Foundation
import Testing

@Suite("Build and run script")
struct BuildAndRunScriptTests {
    @Test("--install process enumeration fails closed")
    func installProcessEnumerationFailsClosed() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("awesomux_candidate_pids()"))
        #expect(script.contains("ps -axo pid=,ucomm= 2>&1"))
        #expect(script.contains("unable to enumerate running $APP_NAME processes (ps exited $status)"))
        #expect(script.contains("cannot safely determine whether $bundle is running"))
        // pgrep -x silently misses a name-matching process that is an
        // ancestor of the pgrep call itself (pgrep(1) -a) — the ordinary
        // shape of running this script from inside a running awesoMux pane
        // (awesomux#281). Nothing should invoke pgrep anymore; explaining
        // why in a comment is fine, so check for the removed invocation
        // rather than the bare word.
        #expect(!script.contains("pgrep -x \"$APP_NAME\" 2>&1"))
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

    @Test("terminate_app_bundle refuses to kill a process it is running inside")
    func terminateAppBundleRefusesSelfTermination() throws {
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
    }

    @Test("terminate_app_bundle still kills a target that is not an ancestor")
    func terminateAppBundleKillsNonAncestorTarget() throws {
        let result = try Self.runSelfTerminationGuardSnippet(targetIsAncestor: false)

        #expect(result.exitStatus == 0, "stderr: \(result.error)")
        #expect(result.output.contains("kill_called=yes"), "stdout: \(result.output)")
    }

    @Test("terminate_app_bundle refuses to kill when its own ancestry can't be inspected")
    func terminateAppBundleRefusesWhenAncestryInspectionFails() throws {
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

    @Test("plain run and install keep separate shutdown targets")
    func plainRunAndInstallKeepSeparateShutdownTargets() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        let stagingTermination = try #require(script.range(of: "terminate_app_bundle \"$APP_BUNDLE\""))
        let installBody = try Self.installAppBody(from: script)
        let installTermination = try #require(installBody.range(of: "terminate_app_bundle_and_wait \"$INSTALLED_APP_BUNDLE\""))

        #expect(stagingTermination.lowerBound < installBody.startIndex)
        #expect(installTermination.lowerBound >= installBody.startIndex)
        #expect(!script[..<installBody.startIndex].contains("terminate_app_bundle_and_wait \"$INSTALLED_APP_BUNDLE\""))
    }

    @Test("install and perf-install wait for the old installed process to exit")
    func installAndPerfInstallWaitForOldProcessExit() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("terminate_app_bundle_and_wait() {"))
        #expect(script.contains("escalating to SIGKILL"))

        let installBody = try Self.installAppBody(from: script)
        #expect(installBody.contains("terminate_app_bundle_and_wait \"$INSTALLED_APP_BUNDLE\""))
        #expect(!installBody.contains("terminate_app_bundle \"$INSTALLED_APP_BUNDLE\""))

        let perfInstallCase = try #require(script.range(of: "--perf-install|perf-install)"))
        let nextCase = try #require(script.range(of: "\n  --verify|verify)", range: perfInstallCase.upperBound..<script.endIndex))
        #expect(
            script[perfInstallCase.upperBound..<nextCase.lowerBound].contains("terminate_app_bundle_and_wait \"$INSTALLED_APP_BUNDLE\""))
    }

    @Test("installed builds require Ghostty artifacts from the pinned revision")
    func installedBuildsRequirePinnedGhosttyArtifacts() throws {
        let buildScript = try Self.contents(of: "script/build_and_run.sh")
        let ensureScript = try Self.contents(of: "script/ensure_ghostty_artifacts.sh")

        #expect(buildScript.contains("mode_requires_exact_ghostty_pin()"))
        #expect(buildScript.contains("if mode_requires_exact_ghostty_pin; then"))
        #expect(buildScript.contains(#"$MODE" == "--install""#))
        #expect(buildScript.contains(#"$MODE" == "--perf-install""#))
        #expect(buildScript.contains("export AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH=1"))
        #expect(ensureScript.contains("_ghostty_sha_stamp_matches \"$dir\" || return 1"))
        #expect(ensureScript.contains("Exact pin match required; rebuilding from this worktree's pin."))
        #expect(ensureScript.contains("submodule update --init --recursive -- vendor/ghostty"))
        #expect(ensureScript.contains("merge-base --is-ancestor \"$checked_out_sha\" \"$pinned_sha\""))
        #expect(ensureScript.contains("submodule update -- vendor/ghostty"))
    }

    @Test("exact pin validation accepts matching CRLF SHA stamps")
    func exactPinValidationAcceptsMatchingCRLFSHAStamps() throws {
        let result = try Self.runGhosttySHAStampSnippet()

        #expect(result.exitStatus == 0)
        #expect(result.output.contains("matching=accepted mismatching=rejected"))
    }

    @Test("stages every required third-party license")
    func stagesRequiredThirdPartyLicenses() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("LICENSE_RESOURCES=\"$ROOT_DIR/Resources/Licenses\""))
        #expect(script.contains("cp \"$source_license\" \"$bundled_license\""))
        #expect(!script.contains("$LICENSE_RESOURCES/."))
        #expect(script.contains("Ghostty/LICENSE"))
        #expect(script.contains("zmx/LICENSE"))
        #expect(script.contains("HackNerdFontMono/LICENSE.md"))
        #expect(script.contains("Geist/OFL.txt"))
        #expect(script.contains("swift-toml/LICENSE.md"))
        #expect(script.contains("swift-markdown/LICENSE.txt"))
        #expect(script.contains("swift-markdown/NOTICE.txt"))
        #expect(script.contains("swift-cmark/COPYING"))
    }

    @Test("stages the DesignSystem resource bundle")
    func stagesDesignSystemResourceBundle() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("awesoMux_DesignSystem.bundle"))
        #expect(script.contains("cp -R \"$DESIGN_SYSTEM_RESOURCE_BUNDLE\" \"$APP_RESOURCES/\""))
        #expect(script.contains("Fonts/Geist-Regular.ttf"))
        #expect(script.contains("Fonts/Geist-Medium.ttf"))
        #expect(script.contains("Fonts/Geist-SemiBold.ttf"))
        #expect(script.contains("Fonts/Geist-Bold.ttf"))
    }

    @Test("AMX build initializes a missing worktree submodule")
    func amxBuildInitializesMissingWorktreeSubmodule() throws {
        let script = try Self.contents(of: "script/build_amx.sh")

        let initialization = try #require(script.range(of: "submodule update --init --recursive -- vendor/zmx"))
        let pinCheck = try #require(script.range(of: "check_submodule_pin"))

        #expect(initialization.lowerBound < pinCheck.lowerBound)
    }

    @Test("AMX build selects zmx Zig independently from Ghostty")
    func amxBuildSelectsIndependentZig() throws {
        let script = try Self.contents(of: "script/build_amx.sh")

        #expect(script.contains("AWESOMUX_ZMX_ZIG"))
        #expect(script.contains("Ghostty and zmx may require"))
        #expect(!script.contains("both pin 0.15.x"))
    }

    @Test("Ghostty build removes the duplicate private-external memset")
    func ghosttyBuildLocalizesCompilerRTMemset() throws {
        let script = try Self.contents(of: "script/build_ghostty_xcframework.sh")

        #expect(script.contains("localize_compiler_rt_memset"))
        #expect(script.contains("xcrun nmedit -R /dev/stdin compiler_rt.o"))
        #expect(script.contains("non-external.* _memset$"))
    }

    @Test("local all-tests and preflight isolate blocking and AppKit-heavy suites")
    func localFullTestsUseProcessIsolation() throws {
        let testScript = try Self.contents(of: "script/test.sh")
        let preflight = try Self.contents(of: "script/preflight.sh")

        #expect(testScript.contains("\"$ROOT_DIR/script/test.sh\" timing"))
        #expect(testScript.contains("\"$ROOT_DIR/script/test.sh\" sidebar --skip-build"))
        #expect(testScript.contains("nontiming --skip-build"))
        #expect(testScript.contains("RemoteHandoffTests"))
        #expect(preflight.contains("\"$ROOT_DIR/script/test.sh\" all"))
        #expect(!preflight.contains("\"$ROOT_DIR/script/swift-test.sh\""))
    }

    @Test("compiles the English string catalog into the app bundle")
    func compilesEnglishStringCatalog() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("APP_STRING_CATALOG=\"$APP_LOCALIZATIONS/Localizable.xcstrings\""))
        #expect(script.contains("xcrun xcstringstool compile \"$APP_STRING_CATALOG\""))
        #expect(script.contains("compiled string catalog would overwrite"))
        #expect(script.contains("en.lproj/Localizable.strings"))
        #expect(script.contains("en.lproj/Localizable.stringsdict"))
        #expect(script.contains("<key>CFBundleDevelopmentRegion</key>"))
        #expect(script.contains("<string>en</string>"))
    }

    @Test("app_bundle_in_state propagates process enumeration failures")
    func appBundleInStatePropagatesProcessEnumerationFailures() throws {
        let result = try Self.runProcessStateSnippet(
            appRunningStatuses: [70],
            command: """
                set +e
                app_bundle_in_state /tmp/fake.app running
                status=$?
                printf 'status=%s calls=%s\\n' "$status" "$APP_RUNNING_CALLS"
                exit "$status"
                """
        )

        #expect(result.exitStatus == 70)
        #expect(result.output.contains("status=70 calls=1"))
    }

    @Test("wait_for_app_bundle_state retries a not-running sample")
    func waitForAppBundleStateRetriesNotRunningSample() throws {
        let result = try Self.runProcessStateSnippet(
            appRunningStatuses: [1, 0],
            command: """
                set +e
                wait_for_app_bundle_state /tmp/fake.app running 2 0
                status=$?
                printf 'status=%s calls=%s\\n' "$status" "$APP_RUNNING_CALLS"
                exit "$status"
                """
        )

        #expect(result.exitStatus == 0)
        #expect(result.output.contains("status=0 calls=2"))
    }

    @Test("wait_for_app_bundle_state propagates process enumeration failures")
    func waitForAppBundleStatePropagatesProcessEnumerationFailures() throws {
        let result = try Self.runProcessStateSnippet(
            appRunningStatuses: [70],
            command: """
                set +e
                wait_for_app_bundle_state /tmp/fake.app running 2 0
                status=$?
                printf 'status=%s calls=%s\\n' "$status" "$APP_RUNNING_CALLS"
                exit "$status"
                """
        )

        #expect(result.exitStatus == 70)
        #expect(result.output.contains("status=70 calls=1"))
    }

    @Test("every log stream predicate is scoped to the launched pid")
    func logStreamsArePIDScoped() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("launch_app_and_resolve_pid()"))
        #expect(script.contains("processIdentifier == $pid"))
        #expect(!script.contains(#"--predicate "process == \"$APP_NAME\"""#))
        #expect(!script.contains(#"--predicate "subsystem == \"$LOG_SUBSYSTEM\"""#))
        #expect(script.contains(#"subsystem == \"$LOG_SUBSYSTEM\" AND processIdentifier == $pid"#))
        #expect(script.contains(#"category == \"TerminalDiagnostics\" AND processIdentifier == $pid"#))
        #expect(script.contains(#"category == \"WindowOrderDiagnostics\" AND processIdentifier == $pid"#))
        #expect(script.contains(#"awesomux-shortcuts-${pid}.jsonl"#))
        #expect(script.contains("tail -n +1 -f \"$diagnostics_file\""))
    }

    @Test("window diagnostics are opt-in and use the shared diagnostic launcher")
    func windowDiagnosticsAreOptIn() throws {
        let script = try Self.contents(of: "script/build_and_run.sh")

        #expect(script.contains("--window-diagnostics|window-diagnostics)"))
        #expect(script.contains("run_diagnostics AWESOMUX_WINDOW_ORDER_DIAGNOSTICS stream_window_diagnostics_logs window-order"))
    }

    @Test("pid resolution fails closed for zero multiple and uninspectable candidates")
    func pidResolutionFailuresPropagate() throws {
        let zero = try Self.runPIDResolutionSnippet(pids: [], status: 0)
        let multiple = try Self.runPIDResolutionSnippet(pids: ["101", "202"], status: 0)
        let uninspectable = try Self.runPIDResolutionSnippet(pids: [], status: 70)

        #expect(zero.exitStatus == 1)
        #expect(zero.error.contains("found 0"))
        #expect(multiple.exitStatus == 1)
        #expect(multiple.error.contains("found 2"))
        #expect(uninspectable.exitStatus == 70)
    }

    @Test("terminate_app_bundle_and_wait returns cleanly once the process exits")
    func terminateAppBundleAndWaitReturnsOnceExited() throws {
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
    }

    @Test("terminate_app_bundle_and_wait escalates to SIGKILL when TERM is not enough")
    func terminateAppBundleAndWaitEscalatesToKill() throws {
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
    }

    @Test("terminate_app_bundle_and_wait fails closed when SIGKILL doesn't work either")
    func terminateAppBundleAndWaitFailsWhenKillIgnored() throws {
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
    }

    @Test("terminate_app_bundle_and_wait does not mistake an enumeration failure for a refused SIGTERM")
    func terminateAppBundleAndWaitPropagatesEnumerationFailureWithoutEscalating() throws {
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

    /// Scoped to `install_app()`'s own body (up to the `case "$MODE" in`
    /// dispatch that follows it) — a search bounded only by `script.endIndex`
    /// would still match `--perf-install`'s later call to the same helper and
    /// couldn't tell a regression in `install_app()` itself from one there.
    private static func installAppBody(from script: String) throws -> Substring {
        let installFunction = try #require(script.range(of: "install_app() {"))
        let dispatch = try #require(script.range(of: "\ncase \"$MODE\" in", range: installFunction.upperBound..<script.endIndex))
        return script[installFunction.lowerBound..<dispatch.lowerBound]
    }

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

    private static func ghosttySHAStampFunction(from script: String) throws -> String {
        let start = try #require(script.range(of: "_ghostty_sha_stamp_matches() {")?.lowerBound)
        let end = try #require(script.range(of: "\n# 1. Local artifacts", range: start..<script.endIndex)?.lowerBound)
        return String(script[start..<end])
    }

    private static func runGhosttySHAStampSnippet() throws -> ShellResult {
        let script = try contents(of: "script/ensure_ghostty_artifacts.sh")
        let function = try ghosttySHAStampFunction(from: script)
        let bash = """
            set -euo pipefail
            \(function)

            ROOT_DIR=/tmp/awesomux-sha-stamp-test
            REQUIRE_GHOSTTY_PIN_MATCH=1
            ARTIFACT_DIR="$(mktemp -d)"
            trap 'trash "$ARTIFACT_DIR"' EXIT
            expected_sha=0123456789abcdef0123456789abcdef01234567

            git() { printf '%s\n' "$expected_sha"; }

            printf '%s\r\n' "$expected_sha" > "$ARTIFACT_DIR/.built-from-sha"
            _ghostty_sha_stamp_matches "$ARTIFACT_DIR"

            printf '%s\r\n' fedcba9876543210fedcba9876543210fedcba98 > "$ARTIFACT_DIR/.built-from-sha"
            if _ghostty_sha_stamp_matches "$ARTIFACT_DIR"; then
              exit 1
            fi

            printf 'matching=accepted mismatching=rejected\n'
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

    private static func runPIDResolutionSnippet(pids: [String], status: Int32) throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try pidResolutionFunctions(from: script)
        let output = pids.joined(separator: "\\n")
        let bash = """
            set -euo pipefail
            \(functions)

            open_app() { :; }
            wait_for_app_bundle() { return 0; }
            app_bundle_pids() {
              printf '%b' '\(output)'
              return \(status)
            }

            launch_app_and_resolve_pid /tmp/fake.app
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

    private static func runProcessStateSnippet(appRunningStatuses: [Int32], command: String) throws -> ShellResult {
        let script = try contents(of: "script/build_and_run.sh")
        let functions = try processStateFunctions(from: script)
        let statuses = appRunningStatuses.map(String.init).joined(separator: " ")
        let bash = """
            set -euo pipefail
            \(functions)

            APP_RUNNING_CALLS=0
            APP_RUNNING_STATUSES=(\(statuses))
            APP_RUNNING_DEFAULT_STATUS=1

            app_bundle_is_running() {
              APP_RUNNING_CALLS=$((APP_RUNNING_CALLS + 1))
              local index=$((APP_RUNNING_CALLS - 1))
              local status="${APP_RUNNING_STATUSES[$index]:-$APP_RUNNING_DEFAULT_STATUS}"
              return "$status"
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
}
