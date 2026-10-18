# Sidebar attention journey

Run from the checkout root (macOS 15+, Xcode Swift toolchain):

```sh
python3 script/sidebar-attention-e2e/run.py --output /tmp/sidebar-attention-result
```

The runner creates a temporary Swift executable depending on this checkout's
`AwesoMuxCore` product. It exercises public `SessionStore` transitions and the
production search → pinned → attention projections, checking navigation order
and preserving original group order. It writes `journey.log` and `report.json`
to the chosen output directory and exits nonzero on a failed check/build.
Use a new output directory for each run; existing output is refused so an old
passing report cannot be mistaken for a new result. `source.json` records the
Git revision, dirty-diff hash, and Swift source/runner/package input hashes
before and after the run. A source change during the run fails verification.
Compare the receipt with the intended checkout when reviewing the artifacts;
it does not establish native app or agent-hook behavior.

This verifies store-to-sidebar data flow, not physical rendering, accessibility,
live agent hook delivery, or terminal output detection. It neither launches the
app nor changes user preferences. SwiftPM may need normal cache/network access.
