# Performance Trace Captures

Do not commit raw `.trace`, `.memgraph`, `.logarchive`, or hour-long log
files. Commit only short summaries with date, build commit, launch mode,
workload, observed high-water marks, and the next decision from
`docs/debugging/memory-surface-investigation.md`.
