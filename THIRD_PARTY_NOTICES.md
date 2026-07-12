# Third-party notices

awesoMux includes the following third-party components. Dependency revisions are
recorded in `.gitmodules` and `Package.resolved`.

| Component | Use in awesoMux | License |
| --- | --- | --- |
| [Ghostty](https://github.com/ghostty-org/ghostty) | Terminal runtime and bundled resources | MIT |
| [zmx](https://github.com/neurosnap/zmx) | Built and bundled as the `amx` command-bridge binary | MIT |
| Hack Nerd Font | Bundled terminal font | MIT; public domain; Bitstream Vera License |
| [swift-toml](https://github.com/mattt/swift-toml) | TOML parsing | MIT |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing and rendering | Apache License 2.0 with Runtime Library Exception |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | Transitive dependency of swift-markdown | BSD-2-Clause |

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
