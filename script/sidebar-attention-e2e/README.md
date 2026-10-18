# Sidebar attention journey

Run from any directory (macOS 15+, Xcode Swift toolchain):

```sh
python3 script/sidebar-attention-e2e/run.py --output /tmp/sidebar-attention-result
```

The runner creates a temporary Swift executable depending on this checkout's
`AwesoMuxCore` product. It exercises public `SessionStore` transitions and the
production search → pinned → attention projections, checking navigation order
and preserving original group order. It writes `journey.log` and `report.json`
to the chosen output directory and exits nonzero on a failed check/build.

This verifies store-to-sidebar data flow, not physical rendering, accessibility,
live agent hook delivery, or terminal output detection. It neither launches the
app nor changes user preferences. SwiftPM may need normal cache/network access.
