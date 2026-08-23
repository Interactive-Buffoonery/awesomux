# Bundled third-party licenses

`script/build_and_run.sh` copies this directory to
`awesoMux.app/Contents/Resources/Licenses` and verifies the required files are
present on every build.

The files below are canonical copies from the pinned source revisions recorded
in `.gitmodules` and `Package.resolved`, or from the versioned upstream release
named in the table:

| Component | Pinned revision | Bundled files |
| --- | --- | --- |
| Ghostty | `5851d98615187d85052e41042bcf66e0ccec11d4` | `Ghostty/LICENSE` |
| zmx / amx | `e3bd8f0e72839c9d24a12d54490c4c3bcc869244` | `zmx/LICENSE` |
| Hack Nerd Font Mono | `ryanoasis/nerd-fonts` 3.4.0 (self-reported by the bundled TTFs) | `HackNerdFontMono/LICENSE.md` |
| Geist Sans | `vercel/geist-font` 1.700 (self-reported by the bundled TTFs) | `Geist/OFL.txt` |
| Selenized | `jan-warchol/selenized` v1.0 | `Selenized/LICENSE` |
| swift-toml | `827506c90475e82d5a7f191f950fb3025cbdc0d6` | `swift-toml/LICENSE.md` |
| swift-markdown | `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` | `swift-markdown/LICENSE.txt`, `swift-markdown/NOTICE.txt` |
| swift-cmark | `924936d0427cb25a61169739a7660230bffa6ea6` | `swift-cmark/COPYING` |

When a dependency pin changes, refresh its corresponding files from that exact
revision in the same change. The two font rows record the version the bundled
TTF name tables report, because neither font is fetched by a pinned build step
and there is nothing else to check against.

The two submodule rows are checked against the committed gitlinks by
`AboutWindowInfoTests`, which also verifies each bundled license text is byte-identical to the file at that revision. Both had drifted: neither row had been updated since the initial open-source seed, seven Ghostty bumps earlier. Note that the Ghostty SHA recorded before that fix was never a committed gitlink of this repository at all — it named an upstream source revision, so this column now means the submodule pin specifically.
