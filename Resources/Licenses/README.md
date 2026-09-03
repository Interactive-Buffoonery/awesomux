# Bundled third-party licenses

`script/build_and_run.sh` copies this directory to
`awesoMux.app/Contents/Resources/Licenses` and verifies the required files are
present on every build.

The files below are canonical copies from the pinned source revisions recorded
in `.gitmodules` and `Package.resolved`, or from the versioned upstream release
named in the table:

| Component | Pinned revision | Bundled files |
| --- | --- | --- |
| Sparkle | 2.9.6 | `Sparkle/LICENSE` |
| Ghostty | `3c1ef5b32fc5ea6b93d28493fabf193f595139cf` | `Ghostty/LICENSE` |
| zmx / amx | `91d836b357a0509856461ea586fe6be2cb4a877e` | `zmx/LICENSE` |
| Hack Nerd Font Mono | `ryanoasis/nerd-fonts` 3.4.0 (self-reported by the bundled TTFs) | `HackNerdFontMono/LICENSE.md` |
| Geist Sans | `vercel/geist-font` 1.700 (self-reported by the bundled TTFs) | `Geist/OFL.txt` |
| Selenized | `jan-warchol/selenized` v1.0 | `Selenized/LICENSE` |
| swift-toml | `827506c90475e82d5a7f191f950fb3025cbdc0d6` | `swift-toml/LICENSE.md` |
| swift-markdown | `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` | `swift-markdown/LICENSE.txt`, `swift-markdown/NOTICE.txt` |
| swift-cmark | `924936d0427cb25a61169739a7660230bffa6ea6` | `swift-cmark/COPYING` |
| FreeType | 2.13.2 (`N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub`) | `FreeType/LICENSE.TXT`, `FreeType/FTL.TXT`, `FreeType/GPLv2.TXT` |
| libpng | 1.6.43 (`N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD`) | `libpng/LICENSE` |
| zlib | 1.3.1 (`N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o`) | `zlib/LICENSE` |
| Oniguruma | 6.9.9 (`N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c`) | `Oniguruma/COPYING` |
| GNU gettext libintl | 0.24 (`N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-`) | `GNU-gettext/COPYING.LIB` |
| Dear Bindings | v0.17 / `2b12a29197ec944cd364031a9776cde814546d52` | `DearBindings/LICENSE.txt` |
| Dear ImGui | 1.92.5-docking / `3912b3d9a9c1b3f17431aebafd86d2f40ee6e59c` | `DearImGui/LICENSE.txt` |
| sentry-native | 0.7.8 (`N-V-__8AAPlZGwBEa-gxrcypGBZ2R8Bse4JYSfo_ul8i2jlG`) | `sentry-native/LICENSE` |
| MPack | 1.0 (vendored by sentry-native 0.7.8) | `MPack/LICENSE` |
| stb_sprintf | 1.09 (vendored by sentry-native 0.7.8) | `stb-sprintf/LICENSE` |
| Google Breakpad | `b99f444ba5f6b98cac261cbb391d8766b34a5918` | `Breakpad/LICENSE` |
| simdutf | 9.0.0 / `ca7acbcea967b5dcbab490066e99e3a6e6925539` | `simdutf/LICENSE-MIT`, `simdutf/LICENSE-APACHE`, `simdutf/NOTICE-BSD3` |
| Highway | 1.2.0 / `66486a10623fa0d72fe91260f96c892e41aceb06` | `Highway/LICENSE`, `Highway/LICENSE-BSD3` |
| glslang | 14.2.0 (`N-V-__8AABzkUgISeKGgXAzgtutgJsZc0-kkeqBBscJgMkvy`) | `glslang/LICENSE.txt` |
| SPIRV-Cross | 13.1.1 (`N-V-__8AANb6pwD7O1WG6L5nvD_rNMvnSc9Cpg1ijSlTYywv`) | `SPIRV-Cross/LICENSE`, `SPIRV-Cross/KhronosFreeUse.txt` |
| Wuffs | `7411f488fe2e2c205c3d3b3d28638b7356522930` (`N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI`) | `Wuffs/LICENSE`, `Wuffs/LICENSE-APACHE`, `Wuffs/LICENSE-MIT` |
| Zig compiler runtime | Compatible 0.16.x toolchain (exact artifact version stamped at build time; license copied from 0.16.0) | `Zig/LICENSE` |

When a dependency pin changes, refresh its corresponding files from that exact
revision in the same change. The two font rows record the version the bundled
TTF name tables report, because neither font is fetched by a pinned build step
and there is nothing else to check against.

The two submodule rows are checked against the committed gitlinks by
`AboutWindowInfoTests`, which also verifies each bundled license text is byte-identical to the file at that revision. Both had drifted: neither row had been updated since the initial open-source seed, seven Ghostty bumps earlier. Note that the Ghostty SHA recorded before that fix was never a committed gitlink of this repository at all — it named an upstream source revision, so this column now means the submodule pin specifically.

The GhosttyKit rows are different from ordinary source dependencies: each is
present in the statically linked ReleaseFast archive at the recorded Ghostty
pin. `script/ghostty-third-party-components.tsv` records the audit provenance,
a representative archive member for every component, and a digest of the full
sorted member inventory. `script/check_ghostty_third_party_licenses.sh` makes a
Ghostty pin or archive-composition change fail until that binary audit and these
license copies are refreshed. Dependencies declared by Ghostty but absent from
the macOS archive are intentionally not listed here.

### Refreshing the GhosttyKit audit

After changing the Ghostty pin, build its ReleaseFast artifact and confirm the
artifact stamps name the expected source and toolchain:

```sh
./script/check_ghostty_license_pins.sh
AWESOMUX_GHOSTTY_OPTIMIZE=ReleaseFast \
  AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH=1 \
  ./script/ensure_ghostty_artifacts.sh
head -n 1 .build/ghostty/.built-from-sha .build/ghostty/.built-zig-version
```

Generate the complete sorted inventory without deduplicating same-named
objects, then update the count and digest in the manifest:

```sh
LIB=.build/ghostty/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a
members_file="$(mktemp -t awesomux-ghostty-members)"
xcrun ar t "$LIB" | LC_ALL=C sort > "$members_file"
wc -l "$members_file"
shasum -a 256 "$members_file"
```

Do not update only the digest. Review every added or removed member, map it to
the producing archive and Ghostty's exact pinned package source, and refresh
the component row, license copies, bundle staging, About actions, and notices
together. Finish with `./script/test-ghostty-third-party-licenses.sh` and
`./script/check_ghostty_third_party_licenses.sh` before the full preflight.
