#!/usr/bin/env python3
"""
WCAG contrast check for sidebar workspace-group color rendering.

Workspace group colors are identity chrome: group dot/header, active-row rail,
and glow. They are not text-bearing tile backgrounds. Sidebar tile row text must
sit on stable semantic surfaces and clear AA independent of the selected tint.

Required gates (exit 1 on failure):

  Text (4.5:1, WCAG 1.4.3 AA):
  - default tile: Color.aw.text on Color.aw.surface.elevated (= surface0)
  - hover tile:   Color.aw.text on surface.hover (= text at 0.06 alpha over surface0)
  - rail secondary text (group header name, workspace count, jump digit,
    pinned chrome): Color.aw.railText on mantle. Latte uses subtext1; Mocha/HC
    keep subtext0 (F44).

  Non-text state/identity chrome (3:1, WCAG 1.4.11):
  - group disclosure chevrons and pinned section pin glyph on mantle: railText
  - active-tile selection border: Color.aw.tintBorder(_:) per tint, vs the tile
    fill (surface0) AND the sidebar (mantle) — the stroke is centered on the
    tile edge, so it straddles both backdrops
  - active-tile border under Increase Contrast: dividerHoverHC vs surface0/mantle
  - group tint-marker HC ring: dividerRestHC vs mantle
  - needs-attention tile border under Increase Contrast: Status.needs HC hex at
    0.95 alpha over surface0/mantle
  - status dot states that render on the sidebar (mantle): needs, error,
    thinking (collapsed-group attention rollup), output (SidebarStatusFooter) —
    both normal and HC hexes
  - the expanded-row needs dot on the tile fill (SidebarSessionTile trailing
    dots render on surface.elevated, not mantle), including the hovered tile
    (surface.hover composites text at 0.06 alpha over surface0 — non-active
    tiles get this backdrop on hover)
  - the HC needs border and needs dot against the hovered tile (HC hover
    composites the HC text token)
  - HC rest border against the hovered tile: uses dividerHoverHC (F44;
    dividerRestHC alone is 2.84:1 Latte on hover)
  - backgrounded-floating-work dot: Status.floatingWork on surface.elevated
    (sole visual carrier; F44)

  Excluded from the non-text gate, deliberately:
  - `idle` — its low contrast IS the signal (see Status.idle in AwColor.swift)
  - waiting/running/done — not rendered as dots on mantle in production
  - normal-mode needs border (Status.needs at 0.50 alpha): currently below 3:1
    in both themes (2.94 mocha / 1.97 latte vs surface0). It is NOT the sole
    carrier of the needs state (the status badge is redundant), so it stays
    report-only. If a design change ever makes the border the sole carrier,
    promote it to the hard gate. Follow-up from INT-480.

All ratios are token-level: blended strokes are checked as ideal composited
token contrast only. The script does not model antialiasing, centered-stroke
pixel coverage (active borders draw at 0.75-1.5pt centered strokes), or the
rasterized edge — a green run proves the tokens, not the rendered pixels.

Genuinely-decorative tint chrome is still reported for design visibility but is
not a failure: the same information is carried by readable group text and
accessibility labels.

Hex values are hand-synced from Sources/DesignSystem/Tokens/AwColor.swift.

Source contracts (same exit code): the script also greps live sidebar call sites
so reverting a tuned token (e.g. floating-work back to raw teal) fails even when
the hand-synced hex tables still pass. Hex tables alone do not prove production
Swift still uses them.

Wired into `./script/preflight.sh` and `.github/workflows/tint-contrast.yml`
(path-filtered PR gate). Also safe to run standalone whenever tokens in
AwColor.swift change or sidebar tint/status chrome is touched — re-sync the
hex tables below first.

Run: python3 script/check_tint_contrast.py
Exit: 0 = all required gates pass, 1 = any required gate fails.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Production call-site contracts. Each entry is (relative path, required substrings).
# Keep this tight to F44-audited surfaces so the gate fails if a token is
# "fixed" in AwColor.swift / this script but not wired at the live call site.
SOURCE_CONTRACTS: list[tuple[str, list[str]]] = [
    (
        "Sources/awesoMux/Views/SidebarSessionTile.swift",
        [
            "Color.aw.status.floatingWork",
            "Color.aw.railText",
            "isHovered ? Color.aw.dividerHoverHC : Color.aw.dividerRestHC",
        ],
    ),
    (
        "Sources/awesoMux/Views/SidebarGroupHeaderView.swift",
        [
            "Color.aw.railText",
        ],
    ),
    (
        "Sources/awesoMux/Views/SidebarPinnedSectionView.swift",
        [
            "Color.aw.railText",
        ],
    ),
    (
        "Sources/DesignSystem/Tokens/AwColor.swift",
        [
            "public var railText: Color",
            "public var floatingWork: Color",
            'latte: latte.subtext1',
            'latte: "#116e74"',  # floatingWork Latte darkening (shared with done)
        ],
    ),
]


# ----- Token table (sync with Sources/DesignSystem/Tokens/AwColor.swift) -----

CATPPUCCIN_MOCHA = {
    "mauve": "#cba6f7",
    "peach": "#fab387",
    "green": "#a6e3a1",
    "teal": "#94e2d5",
    "blue": "#89b4fa",
    "pink": "#f5c2e7",
    "yellow": "#f9e2af",
    "red": "#f38ba8",
    "gray": "#a6adc8",
    "sky": "#89dceb",
    "lavender": "#b4befe",
    "text": "#cdd6f4",
    "subtext0": "#a6adc8",  # text2
    "subtext1": "#bac2de",
    "surface0": "#313244",  # surface.elevated
    "mantle": "#181825",  # surface.sidebar
}

CATPPUCCIN_LATTE = {
    "mauve": "#8839ef",
    "peach": "#fe640b",
    "green": "#40a02b",
    "teal": "#179299",
    "blue": "#1e66f5",
    "pink": "#ea76cb",
    "yellow": "#df8e1d",
    "red": "#d20f39",
    "gray": "#6c6f85",
    "sky": "#04a5e5",
    "lavender": "#7287fd",
    "text": "#4c4f69",
    "subtext0": "#6c6f85",  # text2
    "subtext1": "#5c5f77",  # railText Latte slot
    "surface0": "#ccd0da",  # surface.elevated
    "mantle": "#e6e9ef",  # surface.sidebar
}

TINT_NAMES = [
    "mauve", "peach", "green", "teal", "blue", "pink", "yellow", "red",
    "gray", "sky", "lavender",
]
HOVER_ALPHA = 0.06

# Active-tile selection border (sync with AwColors.tintBorder(_:)).
# Mocha draws the raw tint hex; Latte draws AwTintAccent.latteBorderHex.
ACTIVE_BORDER = {
    "mocha": {name: CATPPUCCIN_MOCHA[name] for name in TINT_NAMES},
    "latte": {  # AwTintAccent.latteBorderHex
        "mauve": "#8839ef",
        "peach": "#c14701",
        "green": "#327e22",
        "teal": "#137b81",
        "blue": "#084fbd",
        "pink": "#c91f9c",
        "yellow": "#835100",
        "red": "#b00030",
        "gray": "#5c5f77",
        "sky": "#0376a4",
        "lavender": "#405cfc",
    },
}

# Increase Contrast divider tokens (sync with AwColors.dividerHoverHC /
# dividerRestHC — the per-theme hex that renders when HC is active).
DIVIDER_HOVER_HC = {"mocha": "#a6adc8", "latte": "#5c5f77"}
DIVIDER_REST_HC = {"mocha": "#9399b2", "latte": "#6c6f85"}

# Status colors rendered as dots on the sidebar (mantle) — sync with
# AwColors.Status. Each entry: (normal hex, HC hex) per theme.
# needs/error/thinking reach mantle via the collapsed-group attention rollup;
# output via SidebarStatusFooter.
STATUS_ON_MANTLE = {
    "needs": {"mocha": ("#fab387", "#ffc8a3"), "latte": ("#ad4001", "#9b3d07")},
    "error": {"mocha": ("#f38ba8", "#ffb3c4"), "latte": ("#d20f39", "#b00030")},
    "thinking": {"mocha": ("#cba6f7", "#dcc2ff"), "latte": ("#8839ef", "#6f20d1")},
    "output": {"mocha": ("#a6e3a1", "#c2f5bd"), "latte": ("#2d711f", "#29661c")},
}

# Status.floatingWork — sole-carrier tile dot (sync with AwColor.swift).
# Same Latte darkening as Status.done (shared teal-on-elevated class).
FLOATING_WORK = {
    "mocha": ("#94e2d5", "#b0f4ea"),
    "latte": ("#116e74", "#00685c"),
}

# Color.aw.railText — secondary text on mantle (F44).
# Mocha/HC: subtext0; Latte: subtext1.
RAIL_TEXT = {
    "mocha": CATPPUCCIN_MOCHA["subtext0"],
    "latte": CATPPUCCIN_LATTE["subtext1"],
}

# Needs-attention tile border alphas (sync with SidebarSessionTile.tileBorder).
NEEDS_BORDER_ALPHA = 0.50
NEEDS_BORDER_ALPHA_HC = 0.95

# The hover overlay composites the theme's text token at 0.06 alpha over the
# tile (surface.hover in AwColor.swift). Under Increase Contrast the text
# token resolves to the HC variant, so the HC hover backdrop differs.
TEXT_HC = {"mocha": "#ffffff", "latte": "#0a0a14"}


# ----- Color math (WCAG 2.x relative luminance + contrast ratio) -----

def hex_to_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore


def blend_over(
    fg: tuple[float, float, float],
    bg: tuple[float, float, float],
    alpha: float
) -> tuple[float, float, float]:
    return tuple(fg[i] * alpha + bg[i] * (1 - alpha) for i in range(3))  # type: ignore


def channel_lin(c: float) -> float:
    # 0.04045 cutoff per the WCAG 2.x errata (matches AwColorTests' oracle).
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: tuple[float, float, float]) -> float:
    r, g, b = (channel_lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    la, lb = relative_luminance(a), relative_luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


# ----- Report -----

@dataclass(frozen=True)
class Row:
    theme: str
    surface: str
    ratio: float


def check_text_surfaces(theme: str, palette: dict[str, str]) -> tuple[list[Row], list[str]]:
    text = hex_to_rgb(palette["text"])
    surface = hex_to_rgb(palette["surface0"])
    mantle = hex_to_rgb(palette["mantle"])
    hover_surface = blend_over(text, surface, HOVER_ALPHA)
    rail_text = hex_to_rgb(RAIL_TEXT[theme])

    rows = [
        Row(theme, "surface.elevated", contrast_ratio(text, surface)),
        Row(theme, "surface.elevated + hover", contrast_ratio(text, hover_surface)),
        Row(theme, "railText / sidebar", contrast_ratio(rail_text, mantle)),
    ]
    failures = [
        f"{row.theme}/{row.surface}: text = {row.ratio:.2f}:1 (< 4.5)"
        for row in rows
        if row.ratio < 4.5
    ]
    return rows, failures


def check_state_surfaces(theme: str, palette: dict[str, str]) -> tuple[list[Row], list[str]]:
    """Non-text state/identity chrome — WCAG 1.4.11's 3:1 floor, hard gate."""
    surface = hex_to_rgb(palette["surface0"])
    mantle = hex_to_rgb(palette["mantle"])
    # Non-active tiles composite surface.hover on hover; the needs cues can
    # sit on that backdrop. (Active tiles never get the hover overlay, so
    # active-border rows stay on the resting fill.)
    hover_surface = blend_over(hex_to_rgb(palette["text"]), surface, HOVER_ALPHA)
    hover_surface_hc = blend_over(hex_to_rgb(TEXT_HC[theme]), surface, HOVER_ALPHA)
    rows: list[Row] = []

    # Active selection border straddles the tile fill and the sidebar.
    for tint in TINT_NAMES:
        border = hex_to_rgb(ACTIVE_BORDER[theme][tint])
        rows.append(Row(theme, f"active border {tint} / tile", contrast_ratio(border, surface)))
        rows.append(Row(theme, f"active border {tint} / sidebar", contrast_ratio(border, mantle)))

    # Increase Contrast: active tile border and group tint-marker ring.
    hover_hc = hex_to_rgb(DIVIDER_HOVER_HC[theme])
    rows.append(Row(theme, "HC active border / tile", contrast_ratio(hover_hc, surface)))
    rows.append(Row(theme, "HC active border / sidebar", contrast_ratio(hover_hc, mantle)))
    # dividerRestHC also draws the non-active tile border under HC
    # (SidebarSessionTile.tileBorder), so gate it against both backdrops —
    # HC users lean on it to find tile bounds, and Latte-vs-tile sits at
    # 3.20:1, close enough to the floor to need a gate watching it.
    rest_hc = hex_to_rgb(DIVIDER_REST_HC[theme])
    rows.append(Row(theme, "HC rest border+ring / tile", contrast_ratio(rest_hc, surface)))
    rows.append(Row(theme, "HC rest border+ring / sidebar", contrast_ratio(rest_hc, mantle)))
    # Hovered HC non-active tiles switch to dividerHoverHC (F44).
    rows.append(Row(theme, "HC hover rest border / hover tile", contrast_ratio(hover_hc, hover_surface_hc)))

    # Needs border, HC variant only — the normal 0.50-alpha variant is
    # report-only (see module docstring).
    needs_hc = hex_to_rgb(STATUS_ON_MANTLE["needs"][theme][1])
    for bg_name, bg in (("tile", surface), ("hover tile", hover_surface_hc), ("sidebar", mantle)):
        blended = blend_over(needs_hc, bg, NEEDS_BORDER_ALPHA_HC)
        rows.append(Row(theme, f"HC needs border / {bg_name}", contrast_ratio(blended, bg)))

    # Status dots on the sidebar, normal + HC hexes.
    for state, themes in STATUS_ON_MANTLE.items():
        normal, hc = themes[theme]
        rows.append(Row(theme, f"dot {state} / sidebar", contrast_ratio(hex_to_rgb(normal), mantle)))
        rows.append(Row(theme, f"HC dot {state} / sidebar", contrast_ratio(hex_to_rgb(hc), mantle)))

    # Expanded-row needs dot renders on the tile fill, not the sidebar —
    # including the hovered variant of the tile.
    needs_normal, needs_hc_hex = STATUS_ON_MANTLE["needs"][theme]
    rows.append(Row(theme, "dot needs / tile", contrast_ratio(hex_to_rgb(needs_normal), surface)))
    rows.append(Row(theme, "dot needs / hover tile", contrast_ratio(hex_to_rgb(needs_normal), hover_surface)))
    rows.append(Row(theme, "HC dot needs / tile", contrast_ratio(hex_to_rgb(needs_hc_hex), surface)))
    rows.append(Row(theme, "HC dot needs / hover tile", contrast_ratio(hex_to_rgb(needs_hc_hex), hover_surface_hc)))

    # Backgrounded floating-work sole-carrier dot on the tile fill.
    fw_normal, fw_hc = FLOATING_WORK[theme]
    rows.append(Row(theme, "floating-work dot / tile", contrast_ratio(hex_to_rgb(fw_normal), surface)))
    rows.append(Row(theme, "HC floating-work dot / tile", contrast_ratio(hex_to_rgb(fw_hc), surface)))

    failures = [
        f"{row.theme}/{row.surface}: {row.ratio:.2f}:1 (< 3.0 non-text floor)"
        for row in rows
        if row.ratio < 3.0
    ]
    return rows, failures


def report_only_rows(theme: str, palette: dict[str, str]) -> list[Row]:
    """Known sub-threshold surfaces, reported but not gated (see docstring)."""
    surface = hex_to_rgb(palette["surface0"])
    mantle = hex_to_rgb(palette["mantle"])
    needs = hex_to_rgb(STATUS_ON_MANTLE["needs"][theme][0])
    rows = []
    # All three backdrops, mirroring the gated HC variant, so the follow-up
    # fix gets tuned against complete numbers.
    hover_surface = blend_over(hex_to_rgb(palette["text"]), surface, HOVER_ALPHA)
    for bg_name, bg in (("tile", surface), ("hover tile", hover_surface), ("sidebar", mantle)):
        blended = blend_over(needs, bg, NEEDS_BORDER_ALPHA)
        rows.append(Row(theme, f"needs border @0.50 / {bg_name}", contrast_ratio(blended, bg)))
    return rows


@dataclass(frozen=True)
class DecorativeTintRow:
    theme: str
    tint: str
    on_tile: float
    on_sidebar: float


def decorative_tint_report(theme: str, palette: dict[str, str]) -> list[DecorativeTintRow]:
    surface = hex_to_rgb(palette["surface0"])
    sidebar = hex_to_rgb(palette["mantle"])
    rows: list[DecorativeTintRow] = []
    for tint in TINT_NAMES:
        hue = hex_to_rgb(palette[tint])
        rows.append(
            DecorativeTintRow(
                theme=theme,
                tint=tint,
                on_tile=contrast_ratio(hue, surface),
                on_sidebar=contrast_ratio(hue, sidebar),
            )
        )
    return rows


def fmt_text(r: float) -> str:
    flag = " " if r >= 4.5 else ("!" if r >= 3 else "X")
    return f"{r:5.2f}:1 {flag}"


def fmt_ui(r: float) -> str:
    flag = " " if r >= 3 else "decor"
    return f"{r:5.2f}:1 {flag}"


def fmt_state(r: float) -> str:
    # Gated rows fail, they aren't "decor" — keep the vocabulary honest.
    flag = " " if r >= 3 else "X"
    return f"{r:5.2f}:1 {flag}"


def fmt_report(r: float) -> str:
    # Report-only rows are state/identity surfaces below the floor, not
    # decorative — flag them as known gaps, not "decor".
    flag = " " if r >= 3 else "gap"
    return f"{r:5.2f}:1 {flag}"


def check_source_contracts() -> list[str]:
    """Fail if audited call sites no longer reference the tuned tokens."""
    failures: list[str] = []
    for rel_path, needles in SOURCE_CONTRACTS:
        path = ROOT / rel_path
        if not path.is_file():
            failures.append(f"missing source file: {rel_path}")
            continue
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                failures.append(f"{rel_path}: missing required token/call-site string {needle!r}")
    return failures


def main() -> int:
    all_fail: list[str] = []
    text_rows: list[Row] = []
    state_rows: list[Row] = []
    info_rows: list[Row] = []
    tint_rows: list[DecorativeTintRow] = []

    for theme, palette in (("mocha", CATPPUCCIN_MOCHA), ("latte", CATPPUCCIN_LATTE)):
        rows, failures = check_text_surfaces(theme, palette)
        text_rows += rows
        all_fail += failures
        rows, failures = check_state_surfaces(theme, palette)
        state_rows += rows
        all_fail += failures
        info_rows += report_only_rows(theme, palette)
        tint_rows += decorative_tint_report(theme, palette)

    contract_fail = check_source_contracts()

    print("\n=== Required sidebar tile text contrast (4.5:1) ===")
    print(f"{'theme':<8}{'surface':<38}{'text':>12}")
    for row in text_rows:
        print(f"{row.theme:<8}{row.surface:<38}{fmt_text(row.ratio):>12}")

    print("\n=== Required state/identity chrome contrast (3:1 non-text) ===")
    print(f"{'theme':<8}{'surface':<38}{'ratio':>12}")
    for row in state_rows:
        print(f"{row.theme:<8}{row.surface:<38}{fmt_state(row.ratio):>12}")

    print("\n=== Known sub-threshold surfaces (report-only, see docstring) ===")
    print(f"{'theme':<8}{'surface':<38}{'ratio':>12}")
    for row in info_rows:
        print(f"{row.theme:<8}{row.surface:<38}{fmt_report(row.ratio):>12}")

    print("\n=== Decorative tint chrome contrast (informational) ===")
    print("Tint chrome is not counted as a failure because row text does not sit on it.")
    print("'decor' means the tint is below the 3:1 non-text floor and must stay redundant.")
    print(f"{'theme':<8}{'tint':<10}{'vs tile':>12}{'vs sidebar':>14}")
    for row in tint_rows:
        print(f"{row.theme:<8}{row.tint:<10}{fmt_ui(row.on_tile):>12}{fmt_ui(row.on_sidebar):>14}")

    print("\n=== Source call-site contracts ===")
    if contract_fail:
        for failure in contract_fail:
            print(f"  X {failure}")
    else:
        print(f"  {len(SOURCE_CONTRACTS)} audited files still reference the tuned tokens.")

    print()
    if all_fail or contract_fail:
        if all_fail:
            print(f"❌ {len(all_fail)} required contrast failure(s):")
            for failure in all_fail:
                print(f"  - {failure}")
        if contract_fail:
            print(f"❌ {len(contract_fail)} source contract failure(s):")
            for failure in contract_fail:
                print(f"  - {failure}")
        print("\nText legend: ' ' >=4.5  '!' 3.0-4.5  'X' <3.0")
        return 1

    print("✅ Required sidebar text and state-chrome surfaces clear WCAG floors.")
    print("Text legend: ' ' >=4.5  '!' 3.0-4.5  'X' <3.0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
