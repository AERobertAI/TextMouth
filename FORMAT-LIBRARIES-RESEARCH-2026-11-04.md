# Readers for the formats iOS can't read, and for Kindle books (November 4, 2026)

Your requests, November 4:
- "Can you try researching open sourced permissably licensed libraries that could read rtf, .doc, and the other formats the IOS can't read?"
- "Also I want on the todo for parsers for importing drm free .mobi, .azw3, and .kfx books to at least import them and convert them to the intermediate reading format, try searching for public domain forms of these or I can try finding some examples..."

How this was researched:
- Three research agents (Sonnet) worked in parallel: one on documents, one on Ogg audio and braille, and one on Kindle formats and their samples.
- Each read a project's licence from its own licence file, or from its package registry, not from a badge.
- I checked again the facts each recommendation rests on: foliate-js's MIT licence, the libvorbis fix's commit, Apple's braille translator on iOS 26, and the headers of the six Kindle samples.
- The agents' full reports, with every URL, are in `build/orchestrator/formats1104/` (gitignored): `documents-report.md`, `audio-braille-report.md`, and `kindle-report.md`.
- This document builds on `FORMATS-RESEARCH-2026-10-17.md` (the Mac's formats) and `IOS-PORT-RESEARCH-2026-11-03.md` (what iOS lacks).

"Permissive" here means MIT, BSD, Apache 2.0, zlib, ISC, Unlicense, CC0, or public domain. The GPL, LGPL, and MPL are not.

## The answer in short

- **Word 97-2003 (.doc, .dot).** No permissively licensed reader exists in C, C++, Objective-C, or Swift.
  - The permissive ones are Java (Apache POI), JavaScript (word-extractor), Go, and Rust, and they serve as maps, not as libraries.
  - The route is TextMouth's own reader, FMT47 in the TODO, written from Microsoft's published specification: about 300 lines for the compound file, and 450 to 600 for the text, styles, and headings.
- **RTF and RTFD.** No library is needed. iOS's own `NSAttributedString` reads both inside the app.
  - Headings come back as bold, larger text, as they do from textutil on the Mac.
  - TextMouth's own RTF reader (FMT47) would read the real heading styles later. Best references: rtf-parser (Rust, MIT) and rtf.js (JavaScript, MIT).
- **OpenDocument (.odt, .ott) and Word 2003 XML.** No library worth taking. Both are XML, ODT inside a ZIP, so TextMouth's own readers over ZIPFoundation and an XML parser:
  - about 300 to 400 lines for ODT;
  - about 150 to 250 lines for Word 2003 XML.
- **Writing .doc.** No permissive writer exists in a language the app can use. On iOS, export RTF or DOCX instead.
- **Ogg (.ogg, .oga, .opus).** Xiph's own decoders are BSD-licensed C: libogg, libvorbis, libopus, and opusfile.
  - They would be vendored the way LAME is, adding about 0.5 to 0.9 MB (an estimate; nothing was built).
  - libvorbis needs commit 1b75110b of August 4, 2026, which fixes a use-after-free that no release has yet.
- **Braille (BRF, BRL, PEF).** No permissive translator back-translates contracted braille.
  - iOS 26 and macOS 26 have Apple's own, `AXBrailleTranslator`. It would cost nothing if it gives an app its tables; a test on an iPhone decides.
  - Otherwise liblouis, as on the Mac. It is LGPL 2.1 or later, not permissive.
- **The rarer audio the Mac converts with afconvert** (AC-3, E-AC-3, MP1, MP2, AMR, 3GPP, and the compressed forms in AIFC, CAF, and AU). Apple's documentation lists iOS decoders for all of them, so no library is needed. Wave64 is not documented for iOS.
- **Kindle books.**
  - foliate-js's `mobi.js` (MIT) reads MOBI 6 and AZW3, so a permissive reference now exists where the October research found only GPL and LGPL code.
  - KFX has no permissive reader at all.
  - Public-domain MOBI and AZW3 files exist (Project Gutenberg, Standard Ebooks), and two of them are now in the repository's samples. No public KFX made by Amazon's tools was found.

## Part 1: the formats the iOS app can't read yet

On the Mac, three helper programs that TextMouth starts beside itself convert these formats:
- textutil converts RTF, RTFD, Word 97-2003, OpenDocument, and Word 2003 XML;
- afconvert converts Ogg and the rarer audio;
- the TextMouthBraille helper back-translates braille with liblouis.

iOS starts no program beside an app. So each format needs either an Apple framework that reads it inside the app, or a reader built into the app.

### Word 97-2003 (.doc and .dot)

**The format.**
- A .doc is a compound file (OLE2). Its WordDocument stream holds the text and formatting.
- A piece table locates the text.
- The style sheet and each paragraph's properties name its heading style and outline level.
- A .dot is a .doc with a template flag.

**Permissive code.** All of it is reference only, none usable directly:
- **Apache POI's HWPF** (Java, Apache 2.0, verified from its published Maven POM).
  - The most complete: text through the piece table, paragraphs, tables, lists, footnotes, headers, styles, and outline levels.
  - It reads fast-saved files, and has limited support for Word 6 and 95.
  - Its own page says HWPF "has no active maintainer".
  - Its security page warns that legacy formats are "particularly vulnerable" to crafted files. Past CVEs: CVE-2012-0213 and CVE-2017-12626.
- **word-extractor** (JavaScript, MIT, verified).
  - Text only: the body, footnotes, headers, and text boxes, with no headings, lists, or tables.
  - Word 97 and later only. Last release 2021.
  - A good small map of the file header and the piece table.
- **doc2txt** (Go, MIT: GitHub's detection, licence file present). Text only.
- **Two others are unproven:** msdoc (Go, MIT) and litchi (Rust, Apache 2.0). Their quality and provenance are unclear, and litchi says it is not ready for production.

**The compound file underneath.**
- **OLEKit** (Swift, Apache 2.0, verified; a port of olefile, which is BSD 2-clause).
  - Small, about 35 KB of source.
  - Idle since 2023, and not fuzzed.
  - Whether it reads from memory or only from a path is not verified.
- **References:** rust-cfb (Rust, MIT, verified, active), mscfb (Go, Apache 2.0, verified), and SheetJS cfb (JavaScript, Apache 2.0, verified).
- **Recommended:** TextMouth's own reader, about 250 to 350 lines working on `Data`, with caps on sector counts and chain lengths, checked against OLEKit. It could serve legacy .xls later.

**Older and protected files.**
- **Word 6 and Word 95** files are also named .doc. Microsoft's specification covers Word 97 and later only, and only POI reads the older layout. They need a text-only path (about 100 lines) or a clear refusal.
- **Encrypted files** set the header's fEncrypted flag. Refuse them.

**Specifications.** [MS-DOC] and [MS-CFB], both covered by Microsoft's Open Specification Promise.

**Recommendation.**
- TextMouth's own reader (FMT47), compiled for both apps.
- Every offset bounds-checked, with a fuzz test, since legacy Office readers are classic targets for crafted files.
- The Mac keeps textutil until the new reader has proved itself.

### RTF and RTFD

**iOS already reads them.**
- `NSAttributedString` reads RTF and RTFD on iOS, inside the app.
- Apple documents limits for its HTML reader only (main thread only), and none for RTF, so TextMouth would add its own size cap and test large files.
- Headings come back as bold, larger text, which the Mac's heading-by-size pass already turns into headings (FMT13).

**For real heading styles.**
- TextMouth's own RTF reader (FMT47) would handle:
  - groups and destinations;
  - the style sheet's names and `\outlinelevel`;
  - `\u` and `\'` escapes with code pages;
  - tables and lists.
- About 500 to 650 lines.
- References:
  - rtf-parser (Rust, MIT, maintained, released June 2026);
  - rtf.js (JavaScript, MIT, verified);
  - striprtf (Python, BSD 3-clause, text only).

**RTFD** is a folder holding TXT.rtf and its attachments, so the RTF reader reads TXT.rtf.

**Specification.** RTF 1.9.1 (2008, the last version), covered by the Open Specification Promise.

**Recommendation.** `NSAttributedString` on iOS now, and the own reader later, for both apps.

### OpenDocument text (.odt and .ott)

**The format.** A ZIP of XML. Its content.xml holds:
- `text:h` headings with their outline levels;
- lists (`text:list`), tables (`table:table`), and notes (`text:note`);
- page breaks, which come from styles.

**Permissive code.** No permissive Swift or C reader exists. References:
- odfdo (Python, Apache 2.0, current);
- odfpy (Python, your choice of GPL 2 or Apache 2.0);
- the ODF Toolkit (Java, Apache 2.0, archived in 2018).

**Recommendation.**
- TextMouth's own reader over ZIPFoundation and an XML parser, about 300 to 400 lines, with the XML reader's external entities off.
- It reads the real heading levels, which textutil loses on the Mac.

**Specification.** OpenDocument 1.3 (OASIS, 2021).

### Word 2003 XML

**The format.** One XML file, shaped like DOCX's document.xml, with a few elements named differently (`w:listPr`, `w:pStyle`). No library exists.

**Recommendation.** An own reader that shares the DOCX reader's paragraph building, about 150 to 250 lines. Low priority, since the format is rare.

### Writing Word 97-2003 (export)

**What exists.**
- No permissive writer in Swift or C.
- POI writes .doc, warning that files "may be generated incorrectly".
- A Go library that claims to write it is unproven.

**Recommendation.**
- On iOS, export RTF, which Word opens, or DOCX.
- A minimal own writer (about 500 to 800 lines) only if you want .doc there.

### Ogg audio (.ogg, .oga, .opus)

**Why it needs a library.**
- Since October 14, the project's rule forbids decoding Ogg through Apple's frameworks in TextMouth's own process.
- iOS has no helper process to move it into.
- Apple's documentation lists no Ogg container and no Vorbis codec for iOS in any case. It lists the Opus codec only (iOS 11), inside other containers.

**Xiph's decoders, all BSD-licensed C (verified):**
- **libogg 1.3.6** (June 2025): the container.
- **libvorbis.**
  - Its last release, 1.3.7, dates from 2020.
  - Commit 1b75110b of August 4, 2026 fixes a use-after-free in vorbisfile's page seek. No release has it yet, so pin that commit, recording its hash as Vendor's other code records its release.
  - Covered by OSS-Fuzz.
- **libopus 1.6.1** (January 2026), in a decoder-only build. Covered by OSS-Fuzz.
  - It carries royalty-free patent licences from Xiph, Microsoft, and Broadcom.
  - Its licence file says the licences end for anyone who sues claiming Opus infringes a patent.
- **opusfile 0.12** (2020, still maintained in git in 2026), with its HTTP code switched off. Covered by OSS-Fuzz.

Each decodes as a stream with bounded memory. Each gives PCM in chunks that Apple's encoder turns into AAC, as the Mac's converter does inside its helper.

**Not recommended:**
- stb_vorbis (MIT or public domain): unchanged since 2021, with open heap CVEs such as CVE-2023-45681.
- Tremor: no use on an iPhone, which has a floating-point unit.
- Prebuilt XCFrameworks and the small Swift wrappers: they can't be audited or rebuilt from TextMouth's own tree.
- SFBAudioEngine (MIT): a whole playback engine with LGPL parts in its default build.

**Recommendation.**
- Vendor the four under `Vendor/`, as LAME and liblouis are: about 0.5 to 0.9 MB of code (estimated).
- Guard them, since a decoder inside the app's own process can't be killed the way a helper can:
  - caps on size, duration, channels, and chained streams;
  - a no-progress timeout;
  - a fuzz test run on the Mac.
- The fallback remains the iOS research's first answer: no Ogg on iOS at first.

### Braille (BRF, BRL, PEF)

**Reading cells needs no library.**
- PEF is XML of Unicode braille.
- BRF and BRL are ASCII, mapped to cells by TextMouth's own 64-cell table.
- A translator is needed only to turn contracted braille into print to speak.

**liblouis** is LGPL 2.1 or later (verified from its README and licence file; a few tables are LGPL 3), so it is not permissive.
- On an App Store build, static linking means shipping object files that someone could relink.
- Whether that works under Apple's terms has no primary source. It is a question for you, or a lawyer, before any App Store release.

**No permissive back-translator** for contracted UEB or EBAE was found. MathCAT (MIT) translates MathML to braille only.

**New: Apple's own translator.**
- `AXBrailleTranslator` is documented for iOS 26 and macOS 26 (verified).
- It translates print to braille and braille to print with a chosen braille table.
- Which tables it offers an app is not documented. The October research found no tables offered to a test program on macOS.
- If it gives an app English UEB tables, iOS needs no liblouis at all.

**Recommendation.** A short test on an iPhone first. If it fails, liblouis as on the Mac.

### The other audio formats

**What Apple documents for iOS:**
- decoders for AC-3 (iOS 2), E-AC-3 (iOS 9), MP1 and MP2 (iOS 2), and AMR-NB (iOS 2) and AMR-WB (iOS 8);
- the 3GPP, AIFC, CAF, and AU file types;
- no iOS availability at all for Wave64.

**Recommendation.**
- Convert these at import inside the app with `ExtAudioFile`, first asking the system which decoders it has (`kAudioFormatProperty_DecodeFormatIDs`), with the same caps as for Ogg.
- Read PCM Wave64 with TextMouth's own code if Apple's reader refuses it.
- All of this needs a test on a device.

## Part 2: Kindle books (MOBI, AZW3, KFX)

The October 17 research put MOBI (FMT42) and AZW3 (FMT48) in the TODO, with only GPL and LGPL code to study and no AZW3 sample. This research adds a permissive reference, AZW3 samples, and KFX.

### MOBI 6 (.mobi, .prc, and .azw files without KF8)

**The format.**
- A Palm database of records. Record 0's headers give:
  - the compression: PalmDOC's LZ77, or HUFF/CDIC in some older commercial files;
  - the encryption field and the DRM fields.
- The text is old HTML:
  - `filepos` links, which are byte offsets into the text;
  - `mbp:pagebreak` marks;
  - images named by record number.
- Chapters come from the NCX index records (INDX, TAGX, CNCX).

**Size.**
- About 700 lines with tests, where October estimated 500. The extra goes to trailing entries, the index records, and turning `filepos` offsets into anchors before the HTML converter sees the text.
- HUFF/CDIC adds about 120 lines, and can come second.

**DRM.** Refuse when the encryption field is not 0, or the DRM offset is not 0xFFFFFFFF.

**Print pages.**
- A MOBI file carries none.
- Only an APNX file beside the book does. Its layout is not verified: the MobileRead wiki refused every connection.

### AZW3 (KF8)

**The format.**
- The same container, at version 8.
- The text is cut into skeletons and fragments (the SKEL, FRAG, and FDST tables), which a reader joins back into XHTML parts.
- Its kindle:pos, kindle:flow, and kindle:embed links must be rewritten.
- A hybrid file holds a MOBI 6 copy first, and its KF8 part after a boundary that EXTH record 121 names.

**Size.** About 600 lines more than MOBI 6, near 1,300 for the two together, which is about the size of foliate-js's `mobi.js`.

**DRM.** The same two fields, checked in both halves of a hybrid. Amazon's store AZW3 files are almost always protected, and are refused.

### KFX (.kfx, .azw8, .kfx-zip, .kpf)

**The format.**
- A different family: a CONT container of entities in Amazon Ion binary, with numbered symbols from Amazon's catalogue of about 850 names.
- The text is in content fragments, the structure in storylines and sections, and the print page list in the book's navigation.

**No permissive reader exists**, in any language searched.
- The complete readers, calibre's KFX Input plugin (with its kfxlib) and boko, are GPL 3.
- ebook-rs says MIT and KFX, but it only scans the file for printable text.
- Amazon's Ion libraries are Apache 2.0, but know nothing of KFX.

**Size.** 1,700 to 2,300 lines, with only GPL code to study:
- an Ion reader of about 400;
- the container, about 300;
- the storylines, 800 to 1,200;
- the navigation, about 150.

**DRM.** A protected container begins with the bytes EA 44 52 4D 49 4F 4E EE ("DRMION") instead of CONT. Refuse it.

**Recommendation.** Detect and refuse protected KFX first, which is a few lines, and leave the reader for later.

### Permissive code for Kindle formats

**References** (licences verified):
- **foliate-js `mobi.js`** (JavaScript, MIT; I checked its licence file). 1,238 lines.
  - It reads MOBI 6, KF8, HUFF/CDIC, the NCX, and the hybrid boundary.
  - It has no DRM check, no APNX, and no KFX.
  - The file doesn't say where its algorithm came from, so a Swift port should be written from the algorithm, with the MobileRead wiki as a second source.
- **lingo-reader's mobi-parser** (TypeScript, MIT): a port of foliate-js.
- **mobi-rs** (Rust, MIT): MOBI 6, idle since 2022.
- **go-richdoc/mobi** (Go, BSD 3-clause): MOBI 6 only, created in October 2026, quality unproven.
- **swift-ebooks**, product BookKit (Swift, MIT): the only Swift one. Its own status page says HUFF/CDIC and full KF8 rebuilding are missing.

**Study only:** libmobi (LGPL 3), and KindleUnpack, calibre, kfxlib, and boko (all GPL 3).

### Samples

**The six downloaded.** Each was checked by two scripts, the research agent's and mine. All are DRM-free: encryption 0 and no DRM offset.
- **Project Gutenberg's "Kindle" link**, https://www.gutenberg.org/ebooks/1952.kindle.images: MOBI 6, 261,088 bytes.
  - The no-images form, https://www.gutenberg.org/cache/epub/1952/pg1952.mobi, is the same file as the repository's `mobi/pg1952-yellow-wallpaper.mobi`.
  - Terms: public domain in the US, with Project Gutenberg's licence text inside.
- **Project Gutenberg's "KF8" link**, https://www.gutenberg.org/ebooks/1952.kf8.images: KF8 under a .mobi name, 267,281 bytes. Gutenberg is a free source of AZW3-format books.
- **Standard Ebooks' AZW3 of The Time Machine**, https://standardebooks.org/ebooks/h-g-wells/the-time-machine/downloads/h-g-wells_the-time-machine.azw3?source=download: 545,452 bytes, CC0. The cleanest AZW3. The download needs `?source=download`, or the site returns a web page.
- **ebook-rs's Alice in Wonderland, as AZW3 and as KFX:** in an MIT repository, but the files' own terms are not stated.
  - The KFX was written by boko (GPL), not by Amazon's tools.
  - It shows the container's layout, but not what Amazon's tools write.

**Added to the repository's samples**, and listed in `samples.tsv`:
- `azw3/se-the-time-machine.azw3`;
- `mobi/pg1952-yellow-wallpaper-kf8.mobi`.

**Still missing:**
- A hybrid MOBI with a KF8 part. calibre's `ebook-convert`, which is on this Mac, can make one from a public-domain EPUB.
- A KFX made by Amazon's tools. Kindle Previewer 3, with calibre's KFX Output plugin, makes one from an EPUB; neither is installed here.
- A protected sample of each kind, for the refusals. Synthetic ones can be made, as for MOBI.

**Where you could help:**
- a DRM-free KFX of a public-domain book, made with Kindle Previewer, or a .kpf from Kindle Create;
- any DRM-free .azw3 or .mobi of your own that turns out to import badly, once the reader exists.

## What could not be verified

- The MobileRead wiki refused every connection, so the byte layouts come from working code and from the samples.
- Compiled sizes: nothing was built.
- Whether `AXBrailleTranslator` gives tables to an app on iOS.
- Whether iOS 26 has every audio decoder on every device, and how it treats Wave64.
- LGPL and the App Store: no primary source answers it.
- Some licence texts, where only GitHub's licence detection and the file's presence were checked: doc2txt, msdoc, litchi, rtf-parser, striprtf, and odfdo.
- The APNX layout, the Print Replica (.azw4) layout, and KFX voucher files.

## Your answers (November 4)

You said: "libraries compiled into the IOS app but not Mac OS is fine though I think small Text Mouth readers for .doc /odt etc might be good for both so formatting extraction is under our control, same for kfx. It seemse the current Mac compile is 21 mb roughly which is still under my 30 mb line for wanting to look at optimizing again..."

What that settles:
- **Libraries only the iOS app needs** are built into the iOS app alone, while the Mac keeps its helper programs:
  - Xiph's Ogg decoders, while the Mac keeps afconvert in its watched helper;
  - liblouis, if Apple's braille translator fails the iPhone test, while the Mac keeps its braille helper.
- **TextMouth's own readers, in both apps,** so that what is taken from a document's formatting is TextMouth's to decide:
  - Word 97-2003 and RTF (FMT47);
  - OpenDocument (FMT27);
  - Word 2003 XML (FMT53, new);
  - KFX (FMT52).

  On the Mac each replaces textutil for its format once it has been checked against textutil's own reading.
- **Size.** The app is about 21 MB, under your 30 MB line.
  - The own readers are Swift: tens of kilobytes compiled.
  - Xiph's decoders add about 0.5 to 0.9 MB, and only to the iOS app.
