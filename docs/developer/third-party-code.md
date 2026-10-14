# Third-party code

Part of [TextMouth's documentation](../../README.md).

TextMouth itself is under the MIT License, in LICENSE beside this file. It builds in one library by other authors, and uses three Swift packages:

- LAME 3.100's MP3 encoder, "LAME Ain't an MP3 Encoder", by Mike Cheng, Mark Taylor, and The LAME Project (https://lame.sourceforge.io; LAME's own notes give www.mp3dev.org), under the GNU Library General Public License, version 2, whose text is Vendor/lame/COPYING. TextMouth writes MP3 with it (see [Editing audio](../user/editing-audio.md)).
  - Vendor/lame holds the encoder's files of LAME's release tarball, lame-3.100.tar.gz (SHA-256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e), each unchanged: COPYING, LICENSE, README, include/lame.h, and the sources and headers in libmp3lame that LAME's own Makefile builds its library from, less the decoder's glue and the x86 assembly. TextMouth adds two files of its own: config.h, in place of the one LAME's configure script writes, and include/module.modulemap, through which Swift imports lame.h.
  - project.yml builds it as a static library the app links, so `make build` builds the app from that source, and the app can be rebuilt with a changed LAME: replace those files from another release, compare config.h with the one its configure script writes, and run `make check`.
  - The licence asks that a copy of the app given to anyone else carry this notice and the licence's text.
- The Swift packages ZIPFoundation, SwiftSoup, and swift-markdown, with the swift-cmark it builds on, each under its own licence; The make check gate, above, says how their versions are pinned.
