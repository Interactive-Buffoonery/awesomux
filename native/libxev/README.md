# libxev kqueue fixes

The generated Ghostty source uses libxev `819ffa18` plus the kqueue delta from
[farbenbuilds/libxev PR1](https://github.com/farbenbuilds/libxev/pull/1),
base `cbf01bc432a84cd91a99c1cb1031b46416d044c7` to
`86d628ac326d69a097ac42c527b04f3389d20d68`. This keeps a completion from
being queued or performed twice and preserves rearm/cancellation accounting.

The patch includes six regression tests. `batch-regression.zig.inc` adds the
300-pipe reproduction from [the zoxy fix](https://github.com/zoxy-io/libxev/commit/fe5a07b4c2920e254e0c4504e5814999696b63b6).
Both sources are MIT licensed; the copied package retains libxev’s LICENSE.
Existing bundled libxev notices remain applicable.

Preparation fetches Ghostty’s exact content-addressed libxev package into a
private cache, verifies its declared Zig hash, copies it into the generated
source, then applies this patch. A changed dependency declaration or patch
context stops preparation. Neither submodule nor the original package cache is
modified. The extension fingerprint includes both files.

The native build runs the patched package’s full tests using its build’s
optimization mode before compiling Ghostty. Library regressions alone do not
prove the cause of a specific awesoMux pane freeze; see issue #176.
