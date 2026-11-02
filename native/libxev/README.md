# libxev kqueue fixes

The generated Ghostty source uses libxev `819ffa18` plus the kqueue delta from
[farbenbuilds/libxev PR1](https://github.com/farbenbuilds/libxev/pull/1),
base `cbf01bc432a84cd91a99c1cb1031b46416d044c7` to
`86d628ac326d69a097ac42c527b04f3389d20d68`. This keeps a completion from
being queued or performed twice and preserves rearm/cancellation accounting.

The downstream patch includes six regression tests. `batch-regression.zig.inc` adds the
300-pipe reproduction from [the zoxy fix](https://github.com/zoxy-io/libxev/commit/fe5a07b4c2920e254e0c4504e5814999696b63b6).
Both sources are MIT licensed; the copied package retains libxev’s LICENSE.
Existing bundled libxev notices remain applicable.

Preparation fetches Ghostty’s exact content-addressed libxev package into a
private cache, verifies its declared Zig hash, copies it into the generated
source, then applies this patch. A changed dependency declaration or patch
context stops preparation. Neither submodule nor the original package cache is
modified. The extension fingerprint includes every patch and regression file.

The native build runs the patched package’s full tests using its build’s
optimization mode before compiling Ghostty. Library regressions alone do not
prove the cause of a specific awesoMux pane freeze; see issue #176.

`machport.patch` adds automatic disable-after-delivery for Mach-port receives.
The kernel receives the payload before returning from kqueue, so a queue guard
alone cannot stop a second event from overwriting a queued callback’s buffer.
Rearm re-enables the filter only after the callback, with no receive output.
`machport-regressions.zig.inc` checks three distinct payloads and callback counts
across repeated and nested submissions. Both tests fail with the downstream
patch alone. These additions are local to awesoMux.
