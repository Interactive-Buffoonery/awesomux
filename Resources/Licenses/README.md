# Bundled third-party licenses

`script/build_and_run.sh` copies this directory to
`awesoMux.app/Contents/Resources/Licenses` and verifies the required files are
present on every build.

The files below are canonical copies from the pinned source revisions recorded
in `.gitmodules` and `Package.resolved`, or from the versioned upstream font
release named in the table:

| Component | Pinned revision | Bundled files |
| --- | --- | --- |
| Ghostty | `4749c4e93731067049bfbf2e4572061cef2bdd17` | `Ghostty/LICENSE` |
| zmx / amx | `d157eba5fe73cd203ac2083dd2432d5c6bf22da9` | `zmx/LICENSE` |
| Hack Nerd Font Mono | bundled Ghostty font resource | `HackNerdFontMono/LICENSE.md` |
| Geist Sans | `vercel/geist-font` 1.8.0 | `Geist/OFL.txt` |
| swift-toml | `827506c90475e82d5a7f191f950fb3025cbdc0d6` | `swift-toml/LICENSE.md` |
| swift-markdown | `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` | `swift-markdown/LICENSE.txt`, `swift-markdown/NOTICE.txt` |
| swift-cmark | `924936d0427cb25a61169739a7660230bffa6ea6` | `swift-cmark/COPYING` |

When a dependency pin changes, refresh its corresponding files from that exact
revision in the same change.
