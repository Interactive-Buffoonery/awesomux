# Relative Markdown click investigation

Checkout: c365b543d37dafc5e9e2de0d1cae7a6ca406abdc; no production changes.

## Confirmed

- Bare README.md produces no hover/open callback in the built libghostty archive. ./README.md and docs/README.md both produce an OPEN callback. See native.log and probe.m.
- The app-owned quicklook filename probe requires origin.remoteFileContext != nil (GhosttySurfaceMarkdownLinks.swift:15). Declared SSH identity and observed SSH metadata do not satisfy that guard. Thus bare filenames without a saved context have neither native recognition nor the app fallback.
- A temporary actual-app view probe confirmed native=nil/appProbe=nil for bare README.md in managed and observed-unmanaged model panes; ./README.md and docs/README.md had native targets in both. See app.log.
- c365b543 and a0dcb3b6 change downstream confirmation/prefill only, not filename detection.
- Ghostty rejects remote-host OSC 7 for its own local cwd, but resolvePathForOpening returning nil preserves the original relative string for openUrl. That rejection alone does not explain no sheet.

## Limits and failed controls

- The app probe could not validate sheet presentation: NSApp.keyWindow and mainWindow stayed nil, including with the repository AppKit test host. Direct openURLAction control also produced no sheet. The failed sheet assertions are harness limitations, not evidence of the reported product defect.
- The initial probe command exited and app exit UI displaced fixture rows. Holding its child alive corrected that measurement; final word readbacks confirm exact clicked filenames.
- Actual Work Mac mouse events, its linked archive and binary provenance, window/sheet state, and SSH lifecycle state remain unverified. The ./README.md failure remains unresolved.
- No end-to-end remote read, cwd prefill, no-OSC-7 help, accessibility, or full preflight was validated.

## Recommended narrow repair and next diagnosis

- Extend the existing app-owned raw-filename click eligibility to the same remote-pane contexts that openURLAction already routes, while retaining captured-origin, surface/position, native-link, boundary, and per-read confirmation checks. Do not grant network authority from observed cwd/host metadata.
- For ./README.md on the Work Mac, capture one controlled click after emitting printf '\n  ./README.md  \n', with the dev window already focused. Trace native hover target, press/release delivery, GHOSTTY_ACTION_OPEN_URL, current pane remote state, and key/main window plus attachedSheet at authorization. A direct File > Open Markdown check distinguishes sheet presentation from link activation. Compare the staged executable and linked archive build receipts to c365b543.

## Work Mac cleanup

- midnight16 LAN: connection refused. tsmidnight16: connection timeout. No remote process was stopped and no remote checkout changed.
- PID 66638 remains unverified. Before stopping anything, verify PID and executable against ~/personal-dev/awesomux/dist/awesoMux.app/Contents/MacOS/awesoMux. Never kill by app name.
- Restore feat/ssh-management-notice only after checking current branch and worktree cleanliness; no forced checkout or cleanup.

## Evidence reproduction

probe.m links against .build/ghostty/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a with its adjacent Headers and the frameworks listed in Package.swift. Run with GHOSTTY_RESOURCES_DIR pointing to .build/ghostty/share/ghostty. Its action callback claims all actions and only logs open URLs; it does not open external URLs or access remote hosts.

The temporary Swift probe is archived here as ZZMarkdownClickInvestigation.swift, outside all build/test targets. It deliberately retains its failing sheet expectation and direct-open control; it is diagnostic evidence, not a passing regression test. To rerun its app-control experiment, temporarily copy it into Tests/awesoMuxTests, run swift test --filter ZZMarkdownClickInvestigation under the shared validation lease, then trash the copy. It uses an isolated in-memory SessionStore and a cat/sleep fixture, not a real SSH session. Do not interpret a green probe invocation without its readback/control logs as end-to-end proof.


## Re-run the native-library control

From the repository root after preparing the normal Ghostty artifacts:

```sh
mkdir -p /tmp/awesomux-markdown-click-investigation
cp docs/debugging/remote-markdown-click-investigation/config /tmp/awesomux-markdown-click-investigation/config
printf '\033[2J\033[H  README.md  \r\n  ./README.md  \r\n  docs/README.md  \r\n  https://example.com  \r\n' > /tmp/awesomux-markdown-click-investigation/fixture
xcrun clang -fobjc-arc docs/debugging/remote-markdown-click-investigation/probe.m \
  -I .build/ghostty/GhosttyKit.xcframework/macos-arm64/Headers \
  .build/ghostty/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a \
  -framework AppKit -framework Carbon -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework CoreVideo \
  -framework GameController -framework IOSurface -framework Metal \
  -framework QuartzCore -lc++ \
  -o /tmp/awesomux-markdown-click-investigation/probe
GHOSTTY_RESOURCES_DIR="$PWD/.build/ghostty/share/ghostty" \
  /tmp/awesomux-markdown-click-investigation/probe
```

These fixed `/tmp` paths match the archived harness. Use only one instance at a time.
The archived app probe also expects this fixture. Use the host's applicable
native-validation coordination; the earlier `/tmp` build-slot script is specific
to the original personal Mac and is not a Midnight 16 prerequisite.
