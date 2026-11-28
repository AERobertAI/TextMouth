# Third-party code
<!-- id: third-party-code; keys: licences, licenses, vendored code, Vendor folder, attribution, MIT, LGPL, check-ios-licenses; src: project.yml, TextMouthProductionTests/BundledLicenseTests.swift, TextMouthiOSTests/BundledLicenseIOSTests.swift, Scripts/ios/check-licenses.py, Vendor/package-licenses/ZIPFoundation/LICENSE -->

Part of [TextMouth's documentation](../../README.md).

TextMouth itself is under the MIT License, in LICENSE at the top of the repository.
It builds in four libraries by other authors (LAME, liblouis, SwiftSoup, and FFmpeg), follows a fourth author's code closely in its Kindle reader, and uses two Swift packages, ZIPFoundation and swift-cmark.
The licence files of all ten ship inside the Mac app, in Contents/Resources/Licenses, one folder for each:
- Licenses/LAME holds COPYING and LICENSE;
- Licenses/liblouis holds COPYING.LESSER and README;
- Licenses/foliate-js and Licenses/SwiftSoup hold LICENSE;
- Licenses/ZIPFoundation holds LICENSE;
- Licenses/FFmpeg holds LICENSE.md, COPYING.LGPLv2.1, and a README that names the release, its patches, and its configure lines;
- Licenses/swift-cmark holds COPYING;
- Licenses/TrueAudio holds COPYRIGHT and README, Licenses/WavPack holds COPYING, and Licenses/MonkeysAudio holds License.txt: the notices of the decoders TextMouth's own TTA, WavPack, and Monkey's Audio readers are ported from.

Both apps ship the same folders.
The file project.yml copies them from Vendor, never into the repository a second time, so each stays its author's own text.
The package and decoder licences are in Vendor/package-licenses, unchanged from their sources.
BundledLicenseTests and BundledLicenseIOSTests check that they reach the built apps.
`make check-ios-licenses` (Scripts/ios/check-licenses.py) reads project.yml and Package.resolved with no build.
It fails when a library the iPhone app links has no licence in it, when a copied licence is not the file its entry names, or when the app copies the licence of a library it no longer links.

## LAME, the MP3 encoder
<!-- id: lame-mp3-encoder; keys: LAME, libmp3lame, lame.h, module.modulemap, MP3 export, LGPL 2; src: project.yml, Vendor/lame/COPYING, Vendor/lame/config.h, Vendor/lame/include/lame.h, Vendor/lame/include/module.modulemap -->

LAME 3.100's MP3 encoder, "LAME Ain't an MP3 Encoder", by Mike Cheng, Mark Taylor, and The LAME Project (https://lame.sourceforge.io; LAME's own notes give www.mp3dev.org), under the GNU Library General Public License, version 2, whose text is Vendor/lame/COPYING.
TextMouth writes MP3 with it (see [Editing audio](../user/editing-audio.md)).

- Vendor/lame holds the encoder's files of LAME's release tarball, lame-3.100.tar.gz (SHA-256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e), each unchanged:
  - COPYING, LICENSE, README, include/lame.h;
  - and the sources and headers in libmp3lame that LAME's own Makefile builds its library from, less the decoder's glue and the x86 assembly.

  TextMouth adds two files of its own: config.h, in place of the one LAME's configure script writes, and include/module.modulemap, through which Swift imports lame.h.
- project.yml builds it as a static library the app links, so `make build` builds the app from that source, and the app can be rebuilt with a changed LAME: replace those files from another release, compare config.h with the one its configure script writes, and run `make check`.
- The licence asks that a copy of the app given to anyone else carry this notice and the licence's text, which the app carries in Licenses/LAME (above).

## liblouis, the braille translator
<!-- id: liblouis-braille-translator; keys: liblouis, braille translator, TextMouthBraille, liblouis.h.in, UCS-4, LGPL 2.1, VoiceOver braille tables; src: project.yml, Vendor/liblouis/COPYING.LESSER, Vendor/liblouis/AUTHORS, Vendor/liblouis/config.h, Vendor/liblouis/include/liblouis.h, TextMouthBraille/main.c, TextMouthProductionTests/BrailleFileCodeTests.swift, Vendor/liblouis/TABLES-LICENSES.md, Scripts/packs/braille_tables.py, Scripts/packs/braille_tables_mac.txt, TextMouthProductionTests/BundledLicenseTests.swift; status: incomplete; issues: FU02, QN01 -->

liblouis 3.39.0, the open-source braille translator and back-translator, by John J. Boyer, its founder, and the liblouis contributors (Vendor/liblouis/AUTHORS), under the GNU Lesser General Public License, version 2.1 or any later version, whose text is Vendor/liblouis/COPYING.LESSER.
TextMouth reads and writes braille with it (see [What TextMouth reads: DAISY and braille books](../user/reads-daisy-and-braille.md) and [Exporting braille files](../user/exporting-braille.md)).

- Vendor/liblouis holds, unchanged, these files of liblouis's release tarball, liblouis-3.39.0.tar.gz (https://github.com/liblouis/liblouis/releases/tag/v3.39.0; SHA-256 629fa8cb0dfd9ad457c5bf47a42f0953b673e62c8ad6b1d03ddc4e2bd20008f1, the digest GitHub publishes for it, which project.yml records):
  - COPYING.LESSER, README, AUTHORS, NEWS;
  - the sources and headers in liblouis/ that its Makefile.am builds the library from (liblouis.h.in among them);
  - and tables/, the release's whole folder of tables, every file of it unchanged: the files that are tables, the files they include, and the release's build files (Makefile.am, Makefile.in, README, and the .in templates), which never ship.

  The folder is no resource of either app.
  The build phase "Pack braille tables" packs the files that may ship into each app's BrailleTables.pack, and the app unpacks the tables it needs into its Caches at first use (see [Braille table pack](../architecture/state/braille-table-pack.md)).
  The Mac's pack holds only the files Scripts/packs/braille_tables_mac.txt lists: the four English tables, everything they include, and three display tables.
  The four are Unified English uncontracted (en-ueb-g1.ctb) and contracted (en-ueb-g2.ctb) braille, and English uncontracted (en-us-g1.ctb) and contracted (en_US.tbl) braille as used in the United States.
  BrailleFileCodeTests compare TextMouth's own tables with the display tables en-us-brf.dis (North American Braille ASCII), de-eurobrl6.dis (Eurobraille, six-dot, lowercase, SBS Zürich 2009), and de-eurobrl6u.dis (the same code in capitals), 64 cells of 64.
  No translation table includes them, so the helper never loads them.
- The licenses of the tables are not all the release's own.
  Vendor/liblouis/TABLES-LICENSES.md lists each file by the license its own head states, and what is left out and why.
  `braille_tables.py licenses --write` writes it, and a test keeps it equal to the files.
  A table ships when its license is the GNU Lesser General Public License 2.1 or later, or the file states none and the release's holds, or the user decided it ships (countries.cti).
  A table under LGPL 3, and every table that includes one, is left out of both apps, as is a file only left-out tables use.
  Both apps carry the list in Licenses/liblouis beside COPYING.LESSER and README, and BundledLicenseTests and BundledLicenseIOSTests check that it arrives.
- TextMouth adds two files of its own: config.h, in place of the one liblouis's configure script writes, and include/liblouis.h, the release's liblouis.h.in with its one substitution made, 32-bit wide characters (UCS-4), so every Unicode character and braille cell fits.
  Nothing of the release was run (not configure, make, or any script), and nothing from liblouis's tools/ folder, which is GPL 3, is used.
- project.yml builds it as a static library that the TextMouthBraille helper links, so on the Mac liblouis runs only in that helper and never in TextMouth's own process.
  The iPhone app links its own build, liblouis_iOS, and runs it in the app, since iOS starts no helper: a crash in it would end the app (FU02).
  It is C that reads untrusted braille and text, it has had memory-safety bugs, and it is not thread-safe (see Braille files, in [Imports: braille tables and the translator](../architecture/state/imports-braille-tables.md)).
  Static linking suits the licence while only the source is published, as it does LAME's (QN01 asks what a binary needs): the app's whole source, liblouis's included, is in the repository, so `make build` builds the app from that source, and the app can be rebuilt with a changed liblouis.
- To update it, replace those files from a newer release, make include/liblouis.h again from its liblouis.h.in, compare config.h with what the new sources read, and run `make check`.
- To update the tables:
  - check the tarball's SHA-256 against the digest the release page publishes for it before opening it, and replace Vendor/liblouis/tables with the release's own tables/ folder, unchanged;
  - set PACKAGE_VERSION in config.h and BrailleTableCatalog.bundledLiblouisVersion to the new release, which a test keeps equal to the pack's;
  - run `python3 -I -B Scripts/packs/braille_tables.py licenses --write`, then read what it newly leaves out or ships; a file ships against its own head's license only by the user's decision (ACCEPTED_BY_DECISION in braille_tables.py);
  - build the pack for both profiles: the build fails when a table includes a file the folder lacks, or a file of Scripts/packs/braille_tables_mac.txt is gone, is left out by the license rule, or includes a file the list lacks;
  - run `python3 -I -B -m unittest discover -s Scripts/packs/tests`, whose tests read the real tables, and then `make check`.
  The apps unpack into a folder named for the release, so the new tables unpack beside the old, and the first unpacking removes the folders of other versions.
- The licence asks that a copy of the app given to anyone else carry the licence's text, which the app carries in Licenses/liblouis (above).
- TextMouth also reads, but does not include, VoiceOver's own liblouis tables on the Mac (liblouis 3.34.0 on macOS 26.3, which the Mac records as LGPL 2.1).
  It reads them where they are on the system volume and never copies, changes, or downloads them, so the app does not grow (see the Braille tab, under [Settings: the Braille tab](../user/settings-braille.md)).

## foliate-js's mobi.js, the Kindle reader it follows
<!-- id: foliate-js-mobi-js-kindle; keys: mobi.js, foliate-js, Kindle reader, PalmDOC, HUFF/CDIC, NCX, KF8; src: Vendor/foliate-js/LICENSE, TextMouth/Parsers/MOBIText.swift, TextMouth/Parsers/MOBIIndex.swift, TextMouth/Parsers/MOBIHuffman.swift, TextMouth/Parsers/KF8Layout.swift, TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MOBIHeaders.swift, TextMouth/Parsers/MOBIPalmDatabase.swift -->

foliate-js's mobi.js, the Kindle reader of the book renderer behind the Foliate e-book reader, by John Factotum (https://github.com/johnfactotum/foliate-js), under the MIT License.
The licence's text is Vendor/foliate-js/LICENSE ("Copyright (c) 2022 John Factotum"; SHA-256 b621ffc351fe263bc9b09dd0bc1c9332fda9c462a3904c1e4f0b4d3236b9c28c, the file as of foliate-js commit c986ba68, unchanged).
TextMouth's Kindle reader (see [What TextMouth reads: Kindle books](../user/reads-kindle-books.md)) is Swift of its own, but four of its files follow mobi.js closely (mobi.js last changed in commit 9a676796), and each says so:
- MOBIText.swift (PalmDOC decompression and the records' trailing entries);
- MOBIIndex.swift (the NCX index);
- MOBIHuffman.swift (HUFF/CDIC decompression, whose format leaves little room for another way);
- and KF8Layout.swift (how a KF8 book's skeleton, fragment, and flow tables are read; its join of a document is a piece table of TextMouth's own, and no code is copied).

KF8Book.swift reads mobi.js's getNCX and its kindle:pos links as a map for what a contents entry's two numbers mean.
MOBIHeaders.swift and MOBIPalmDatabase.swift take only the header fields' offsets from it.

- No JavaScript is in the app or the repository: Vendor/foliate-js holds the licence alone.
- The licence asks that its notice go with every copy of the code or of a substantial part of it, which the app carries in Licenses/foliate-js (above).

## FFmpeg, the converter of formats macOS cannot read
<!-- id: ffmpeg-bundled; keys: FFmpeg, libavformat, LGPL 2.1, Credits.rtf, patches, CVE, build.py; src: Scripts/vendor/ffmpeg/build.py, Scripts/vendor/ffmpeg/patches/, Vendor/package-licenses/FFmpeg/README, Vendor/package-licenses/FFmpeg/LICENSE.md, TextMouth/Resources/Credits.rtf, TextMouthProductionTests/BundledLicenseTests.swift, project.yml; status: planned; issues: FU01, FU-FFMPEG2 -->

FFmpeg 9.0.2 (https://ffmpeg.org), under the GNU Lesser General Public License, version 2.1 or later, is built into the helper TextMouthFFmpeg on the Mac and, as the library FFmpeg_iOS, into the iPhone app, which converts WMA, Matroska, WebM, and the other formats macOS cannot read.
The build is in [Building TextMouth](building.md), and the helper in [Imports: audio only FFmpeg reads](../architecture/state/imports-audio-ffmpeg.md).

- Its code is not in the repository: `Scripts/vendor/ffmpeg/build.py` downloads the release, checks it, and builds it, so the app can be rebuilt with a changed FFmpeg.
- No part under the GPL is built: configure is given none of --enable-gpl, --enable-nonfree, and --enable-version3.
- The release is changed in one way: five upstream patches for CVEs the National Vulnerability Database lists as open in 9.0.2 (apedec, mpc7, cook, flac_parser, and vorbis_parser), each kept unchanged in Scripts/vendor/ffmpeg/patches and pinned by its SHA-256.
  Drop them when FFmpeg 9.0.3 includes them (FU01): empty PATCHES, delete the folder, regenerate the README with `build.py --readme`, and change Credits.rtf and BundledLicenseTests to match.
  A patch the new release lacks stays.
- Both apps carry FFmpeg's own LICENSE.md and COPYING.LGPLv2.1 and the README, in Licenses/FFmpeg (`make check-ios-licenses` fails an iPhone app that links a library with no licence), and a credit in the About window (Credits.rtf), with the sentence FFmpeg's legal checklist asks for word for word.
  The credit says "five upstream patches" and does not list their hashes, which VoiceOver would read aloud; the README names each by its commit and CVE.
  BundledLicenseTests checks both.
- LGPL 2.1 section 6 asks that the source travel with a binary carrying FFmpeg, which holds while only source is published; before a binary leaves the project (a release download, TestFlight), host the source tarball beside it or give a written offer (FU-FFMPEG2).

## The Swift packages
<!-- id: swift-packages; keys: ZIPFoundation, swift-cmark, MarkdownTree, Package.resolved, exact version; src: project.yml, Vendor/package-licenses/swift-cmark/COPYING, TextMouth/Parsers/MarkdownTree.swift -->

The Swift packages ZIPFoundation and swift-cmark, each under its own licence, which both apps carry (from Vendor/package-licenses, above).
TextMouth reads Markdown through cmark-gfm directly (MarkdownTree), with no swift-markdown in either app.
[The make check gate](building.md) says how their versions are pinned.

## SwiftSoup, the HTML and XML parser
<!-- id: swiftsoup-vendored; keys: SwiftSoup, jsoup, vendored, markup guard, make_vendor.py, MarkupScanner, Licenses/SwiftSoup; src: project.yml, Vendor/SwiftSoup/README.md, Scripts/vendor/swiftsoup/make_vendor.py, TextMouth/Parsers/MarkupScanner.swift, TextMouth/Parsers/MarkupNesting.swift, TextMouthProductionTests/BundledLicenseTests.swift -->

SwiftSoup 2.13.9 (https://github.com/scinfu/SwiftSoup, under the MIT License, itself a port of jsoup, also MIT) is vendored in Vendor/SwiftSoup, no longer a Swift package.

- `Scripts/vendor/swiftsoup/make_vendor.py` writes its sources from the release with attribute edits only, and its test runs in `make check-selftest` (see Vendor/SwiftSoup/README.md, and [Building TextMouth](building.md)).
- The licence asks that its notice go with every copy of the code or of a substantial part of it, which the app carries in Licenses/SwiftSoup (above); BundledLicenseTests checks it.
- Two files of TextMouth's follow its code closely, as maps and not as copies, so that the markup guard counts what SwiftSoup will build before it builds it:
  - `MarkupScanner` (Parsers/MarkupScanner.swift) follows SwiftSoup's tokeniser, `TokeniserState`, state by state, with its oddities.
  - `HTMLTreeModel` (Parsers/MarkupNesting.swift) follows its tree builder, `HtmlTreeBuilder` and `HtmlTreeBuilderState`, mode by mode, with its slips and not the HTML standard's rules, and `XMLOpenElements` in the same file follows `XmlTreeBuilder`.
  - Both were written from SwiftSoup's source, and when SwiftSoup is updated they must be read against the new source again: a tag or a rule the new version reads differently is a level the guard cannot count (see Shared helpers, in [Architecture](../../ARCHITECTURE.md)).

## No third-party code in the document readers
<!-- id: no-third-party-code-document; keys: clean-room, specifications, RTF, MS-DOC, ECMA-376, OpenDocument, KFX, samples.tsv; src: TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/CompoundFile.swift, TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/KFXParser.swift, Scripts/make-kfx-sample.py, TestData/format-samples/samples.tsv -->

No third-party code is in TextMouth's own document readers: rich text, Word 97-2003, Word (DOCX), OpenDocument text, Word 2003 XML, and Kindle KFX.
Each was written from its format's published specification, and no other reader's source was read or copied.

- The specifications are:
  - Microsoft's Rich Text Format 1.9.1;
  - [MS-DOC], [MS-CFB], and [MS-OLEPS] for Word 97-2003;
  - ECMA-376 for Word (DOCX), where its rule for toggle properties decides hidden text;
  - OASIS's OpenDocument 1.3;
  - Microsoft's Office 2003 XML Reference Schemas for Word 2003 XML;
  - and Amazon's published Ion text and binary specification for KFX's container, with the project's own notes on the KFX format.
- Apache POI's HWPF and the ODF libraries odfdo and the ODF Toolkit were looked at only as maps of a format's structure (the Word piece table's layout; the shape of an OpenDocument package).
  None of their code is used.
  The source code of LibreOffice, antiword, catdoc, wvWare, and every other GPL or LGPL project is never read.
- The KFX reader never decrypts a book and contains no code to.
  The sample KFX books are made by running Amazon's Kindle Previewer and a packaging tool as black boxes (see [Tests of the markup guard, Kindle, and MOBI readers](testing-formats.md)); neither tool's code is in the repository or was read.
- Test files are data, not code.
  The real documents under TestData/format-samples that came from LibreOffice's test data are under MPL-2.0, and the ones that came from Apache POI's test documents are under Apache-2.0; each is listed in TestData/format-samples/samples.tsv with its source and licence.
