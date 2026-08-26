# Third-party notices

awesoMux includes the following third-party components. Direct dependency
revisions are recorded in `.gitmodules` and `Package.resolved`; GhosttyKit's
linked dependency audit is recorded separately as described below.

| Component | Use in awesoMux | License |
| --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Software updates | MIT and bundled third-party notices |
| [Ghostty](https://github.com/ghostty-org/ghostty) | Terminal runtime and bundled resources | MIT |
| [zmx](https://github.com/neurosnap/zmx) | Built and bundled as the `amx` command-bridge binary | MIT |
| Hack Nerd Font | Bundled terminal font | MIT; public domain; Bitstream Vera License |
| [swift-toml](https://github.com/mattt/swift-toml) | TOML parsing | MIT |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing and rendering | Apache License 2.0 with Runtime Library Exception |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | Transitive dependency of swift-markdown | BSD-2-Clause |
| [Geist Sans](https://github.com/vercel/geist-font) | Bundled interface font | SIL Open Font License 1.1 |
| [Selenized](https://github.com/jan-warchol/selenized) | Bundled terminal color scheme | MIT |
| [FreeType](https://freetype.org/) | Statically linked through GhosttyKit for font rendering | FreeType License or GPL-2.0-or-later |
| [libpng](https://libpng.org/) | Statically linked through GhosttyKit for PNG images | PNG Reference Library License v2 |
| [zlib](https://zlib.net/) | Statically linked through GhosttyKit for compression | Zlib |
| [Oniguruma](https://github.com/kkos/oniguruma) | Statically linked through GhosttyKit for regular expressions | BSD-2-Clause |
| [GNU gettext libintl](https://www.gnu.org/software/gettext/) | Statically linked through GhosttyKit for localization | LGPL-2.1-or-later |
| [Dear Bindings](https://github.com/dearimgui/dear_bindings) | C bindings statically linked through GhosttyKit | MIT |
| [Dear ImGui](https://github.com/ocornut/imgui) | Statically linked through GhosttyKit | MIT |
| [sentry-native](https://github.com/getsentry/sentry-native) | Crash runtime statically linked through GhosttyKit | MIT |
| [MPack](https://github.com/ludocode/mpack) | Vendored by sentry-native and statically linked through GhosttyKit | MIT |
| [stb_sprintf](https://github.com/nothings/stb) | Vendored by sentry-native and statically linked through GhosttyKit | MIT or public domain |
| [Google Breakpad](https://chromium.googlesource.com/breakpad/breakpad/) | Crash handling statically linked through GhosttyKit | BSD-3-Clause with bundled Unicode and APSL notices |
| [simdutf](https://github.com/simdutf/simdutf) | Unicode processing statically linked through GhosttyKit | Apache-2.0 or MIT with BSD-3-Clause notice |
| [Highway](https://github.com/google/highway) | SIMD operations statically linked through GhosttyKit | Apache-2.0 and BSD-3-Clause notices |
| [glslang](https://github.com/KhronosGroup/glslang) | Shader compilation statically linked through GhosttyKit | Bundled open-source licenses |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | Shader translation statically linked through GhosttyKit | Apache-2.0 and Khronos notice |
| [Wuffs](https://github.com/google/wuffs) | Image decoding statically linked through GhosttyKit | Apache-2.0 or MIT |
| [Zig compiler runtime](https://ziglang.org/) | Toolchain runtime statically linked into GhosttyKit | MIT |

## Sparkle

Sparkle is copyright its contributors and is licensed under the MIT License.
Its full license, including bundled third-party notices, is included at
`Resources/Licenses/Sparkle/LICENSE`.

## Ghostty

Ghostty is copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors.

```text
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## zmx / amx

awesoMux builds the vendored zmx source as the `amx` executable and ships that
executable with the app when available. zmx is copyright (c) 2025 Eric Bower.

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hack Nerd Font

The bundled `HackNerdFontMono` font is supplied through Ghostty's Nerd Fonts
resources. The Hack project is copyright (c) 2018 Source Foundry Authors and
is licensed under the MIT License. The bundled font also includes work from
the DejaVu project, which is in the public domain, and Bitstream Vera Sans
Mono, licensed under the Bitstream Vera License. The app bundle includes the
full license text alongside the font files.

## swift-toml

swift-toml is copyright 2025 Mattt and is licensed under the MIT License:
<https://github.com/mattt/swift-toml/blob/main/LICENSE.md>.

## swift-markdown

swift-markdown is copyright (c) 2021 Apple Inc. and the Swift project authors.
It is licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
with the following Runtime Library Exception:

```text
As an exception, if you use this Software to compile your source code and
portions of this Software are embedded into the binary product as a result,
you may redistribute such product without providing attribution as would
otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

Its required NOTICE is reproduced below:

```text
The Swift Markdown Project

Copyright (c) 2021 Apple Inc. and the Swift project authors

The Swift Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

This product contains Swift Argument Parser.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-argument-parser

This product contains a derivation of the cmark-gfm project, available at
https://github.com/apple/swift-cmark.

  * LICENSE (BSD-2):
    * https://opensource.org/licenses/BSD-2-Clause
  * HOMEPAGE:
    * https://github.com/github/cmark-gfm
```

## swift-cmark

swift-cmark is a transitive dependency of swift-markdown. Its primary notice
is copyright (c) 2014 John MacFarlane and licensed under BSD-2-Clause:
<https://github.com/swiftlang/swift-cmark/blob/main/COPYING>. That file also
preserves notices for its houdini, GitHub, utf8proc, markdowntest, and
CommonMark-derived sources.

## GhosttyKit static dependencies

The components listed above as statically linked through GhosttyKit were
identified from the ReleaseFast `libghostty-fat.a` built from the pinned
Ghostty submodule. The complete audit record, including source versions,
representative archive members, and the full member-inventory digest, is in
`script/ghostty-third-party-components.tsv`. Full license and notice texts are
bundled under each component's directory in `Resources/Licenses` and are
available from the app's About window.

FreeType is distributed under a choice of the FreeType License or
GPL-2.0-or-later; all three upstream explanatory and license files are bundled.
Breakpad's upstream `LICENSE` is preserved in full because the archive includes
both its Unicode conversion object and Apple-derived macOS object. Crediting
Breakpad as BSD-3-Clause alone would omit those notices.

GNU gettext's libintl runtime is statically linked under LGPL-2.1-or-later.
awesoMux's complete source, pinned Ghostty source, and reproducible build scripts
are public so recipients can rebuild the application with a modified libintl.
This statement describes the materials the project provides; it is not legal
advice or a claim that those materials settle every jurisdiction's requirements.
