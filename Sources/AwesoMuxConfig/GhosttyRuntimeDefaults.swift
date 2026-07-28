public enum GhosttyRuntimeDefaults {
    /// Ghostty's `scrollback-limit` is allocated cell memory (~12.5 bytes per
    /// cell, blank trailing cells included) per terminal surface — not text —
    /// so retained rows depend on window width: rows ≈ bytes / (12.5 × cols).
    /// At ~80 columns: upstream's 10MB default keeps ~10k rows, awesoMux's
    /// original 5MB pick ~5k (INT-397 measured ~7.5k retained from a
    /// 100k-line run at the width then in use), and 64MB keeps ~64k rows
    /// (~26k at 200 columns) — roughly a 9× raise, not full retention of
    /// arbitrary agent runs. Allocation is demand-driven, so panes that never
    /// scroll past the old cap cost nothing new, and the vendored pin returns
    /// free-listed pages to the OS (ghostty #13245) when a filled pane
    /// shrinks again.
    ///
    /// This is a *logical* budget. The vendored pin compresses idle offscreen
    /// pages (`scrollback-compression`, upstream default on), which cuts
    /// physical memory for cold history without changing how much history is
    /// retained — so the numbers above still describe retention, not RSS.
    //
    // ponytail: known ceilings on this number, not yet measured — (1) only
    // pages intersecting the viewport (plus the active-boundary page) stay
    // resident; eligibility is spatial, not time-based, so a page becomes a
    // compression candidate on the next idle tick after it scrolls off-screen.
    // Activity postpones the idle timer, so the worst case for a pane being
    // actively scrolled is still the full uncompressed budget;
    // (2) INT-397 recorded sticky GPU-buffer growth (IOAccelerator
    // DIRTY+SWAPPED) from scrollback fill at the OLD cap, and whether that
    // cost scales with the cap is unanswered — re-run
    // the one-surface Warm-A capture (docs/debugging/perf-traces/) against
    // the committed 5MB baselines before raising this further; (3) the
    // budget is per surface with no app-level total — N concurrently
    // *filled* panes retain N × this cap (8 busy agent panes ≈ 512MB where
    // the old cap held ≈ 40MB), so an app-total policy is the upgrade path
    // if fleet-scale sessions make that bite; (4) the accessibility
    // full-screen read (GhosttySurfaceAccessibility) and its contents cache
    // are O(this cap) on the main actor under the renderer mutex — their
    // cost and retention scale with this number and are queued for the same
    // measurement pass. Compression makes that ceiling worse, not better:
    // any full-scrollback read (VoiceOver screen contents, Show Scrollback,
    // full-scrollback search) walks pins through PageList's `Node.page()`,
    // which decompresses each cold page synchronously and then leaves it
    // resident — so the read pays LZ4 decode under the renderer mutex AND
    // undoes the compression for the range it just read until the next idle
    // pass. Time a cold full-screen read, not just steady-state RSS, when
    // that measurement pass happens.
    public static let scrollbackLimit = 64_000_000

    /// Loaded BEFORE `ghostty_config_load_default_files`, so anything the user
    /// sets in Ghostty's default config files wins (libghostty is last-write-wins).
    /// These are suggestions awesoMux ships as a starting point — the user
    /// remains the source of truth for their own machine. See INT-396.
    public static var defaultConfigContents: String {
        [
            "scrollback-limit = \(scrollbackLimit)"
        ].joined(separator: "\n") + "\n"
    }
}
