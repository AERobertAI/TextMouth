# PowerPoint, Excel, CSV, and picture descriptions: research
<!-- research for the user's request of November 24, 2026; main 5a67ff468 (0.5.11); no code was changed -->

Part of [the research folder](README.md).
Marks used below: **verified** means a primary source was read this session; **observed** means seen in the repository or in a probe on files made for this report; **unchecked** means not confirmed.
The probes were short Python scripts in a scratch folder, run with a time limit on files built from XML text; none is committed.

## Summary

- TextMouth reads none of these formats today: `BookFormat.detect(from:)` has no case for .pptx, .xlsx, .csv, .tsv, .odp, or .ods, so each is refused as unsupported. Keynote and Numbers are refused with advice to export a PDF (observed: `RefusedFormatAdvice.swift`).
- The OOXML and OpenDocument forms are ZIPs of XML, which TextMouth already reads safely for .docx and .odt; its own readers of about 1,000 to 1,500 lines each are cheaper and safer than any library, and they run on both platforms at once.
- No Swift or C library fits better: CoreXLSX (Apache-2.0) reads only .xlsx into memory and none reads .pptx; libxls (BSD-2) reads .xls but runs C on hostile input in-process; nothing permissive reads .ppt. Apple's own frameworks read neither slides nor sheets.
- Slides: each slide is a page, with a heading from its title placeholder ("Slide N" when it has none). Contents are read in z-order, which is the order PowerPoint's screen readers use, with the title first and date, footer, and slide-number placeholders dropped.
- The file's layout can repair a sloppy order: an XY-cut over shape positions (placeholders take their position from the layout) fixed a two-column slide in a probe where the author's order read the right column first.
- Sheets: a heading per visible sheet and a paragraph per row, cells joined by ", ", never a table. TextMouth's own table reading joins cells with one space, which is ambiguous in speech and in braille (observed in `MarkdownParser.readTable`).
- Excel stores no display text: dates and percentages need the cell's number format and the workbook's 1900 or 1904 epoch (the same serial 45123 is 2023-07-16 or 2027-07-17: observed). OpenDocument sheets store the display text, so .ods is simpler.
- Pictures: DrawingML `descr` and `title` (and Microsoft's `decorative` extension) carry the description. Today Word, rich text, and Word 97 pictures are silent (issue DR35), so one shared policy type would fix them and serve the new readers.
- Recommended order: picture policy with .docx, then CSV, then .xlsx and .ods, then .pptx and .odp, then charts and SmartArt text, then the legacy .xls and .ppt. About 5,000 lines of Swift plus tests, no new library.
- Version: new `BookFormat` cases make this a 0.6.0 change by the version policy; the changelog must caution about older builds, as for pictures in 0.5.0.

## Question 1: the formats and what TextMouth already has


- **PowerPoint:** .pptx, .pptm, .ppsx, .ppsm, .potx, .potm share one package layout, `ppt/presentation.xml` with `p:sldIdLst`; macro and template forms differ only by content type, as .docx and .dotx do (observed in `Book.swift`). Legacy .ppt, .pps, .pot are one compound file with a "PowerPoint Document" stream.
- **Excel:** .xlsx, .xlsm, .xltx, .xltm share `xl/workbook.xml`; legacy .xls (BIFF8) is a compound file with a "Workbook" stream (BIFF5 uses "Book", unchecked).
- **OpenDocument:** .odp and .ods are ZIPs with `content.xml`, like .odt.
- **CSV and TSV:** not read. `detect(from:)` gives nil for them, so the import says the format is unsupported (read from the code, not run). A .csv renamed .txt would read as plain text.
- **Keynote and Numbers:** not readable in practice (see below); both are refused today with a PDF-export sentence.
- **Compound-file format of .ppt and .xls:** `CompoundFile` already reads root streams by name with bounds-checked `OLEBytes` and loop guards, written for Word 97 and sized for this (observed: its header comment names legacy Excel and PowerPoint).
- **Reusable as they are:** ZIPFoundation with `ArchiveEntryLimits` (64 MB per text entry) and `DocumentByteLimit`; `PackageSAXParser` and `OfficeXMLReader` (document type refused, 200-element nesting limit, cancellation checks); `DOCXParser+Relationships` for relationship files; `MarkdownPageMarker` and the `doc-pagebreak` route of `OwnDocumentReaders`.
- **Reusable with care:** `OfficeParagraph`, `OfficeBlockWriter`, and `RTFBlockBuilder` hold paragraphs, pages, lists, and tables for the ODT and Word 2003 XML readers; a slide reader can drive them through HTML as `ODTDocumentReader` does. `OfficeParagraph` is built around OpenDocument's white-space rules, so a DrawingML reader should write its paragraphs through the block builder directly.
- **Not reusable:** the DOCX converter writes Markdown directly and is 1,568 lines of Word-specific state; a PowerPoint reader copies its patterns (hidden text, `mc:AlternateContent`, cancellation), not its code.
- **Missing:** math. TextMouth reads no OMML equation in .docx, and KFX math is read as the words of its MathML (observed: `KFXWalk.accessibleName`). A shared OMML-to-words step would serve Word and PowerPoint.

## Keynote and Numbers

- Files made by Keynote and Numbers 2013 and later are ZIPs of Snappy-compressed protobuf `.iwa` files plus images; the protobuf definitions were extracted from the running apps, so new releases break parsers ([keynote-parser README](https://github.com/psobot/keynote-parser), verified by search result; the [SheetJS notes on IWA](https://git.sheetjs.com/sheetjs/notes/raw/commit/e7bc6809cd292eccd5467ab218d46edc013f2429/iwa/README.md) describe the block framing).
- The repository's Pages samples show both generations: `Pages_4.pages` holds `index.xml` and `QuickLook/Preview.pdf`, and `Pages_5.pages` holds `Index/*.iwa` and only JPEG previews (observed).
- A Keynote or Numbers file of the first kind is XML that LibreOffice's libetonyek reads (MPL-2.0 and C++ with Boost: out of scope); the second kind has no spec.
- macOS ships `iWork.mdimporter` and `Office.mdimporter`, Spotlight plug-ins that index flat text. `mdimport -t` on a made deck returned a 429-character text blob and on a made workbook none (observed). They have no public API, no structure, and no iPhone twin.
- **Verdict:** keep refusing. Once .pptx and .xlsx are read, change the advice to "Export Keynote presentations as PowerPoint" and "Export Numbers spreadsheets as Excel or CSV", which both apps do.

## Question 2: libraries or TextMouth's own parsers

### What exists

| Option | Licence | Reads | Verdict |
| --- | --- | --- | --- |
| [CoreXLSX](https://github.com/CoreOffice/CoreXLSX) (Swift) | Apache-2.0, needs XMLCoder and ZIPFoundation | .xlsx only; decompresses in memory; shared strings, styles, `dateValue`; its README does not mention formulas, merged cells, or hidden rows (verified) | No: no streaming, no .pptx, no .xls |
| [OLEKit](https://github.com/PureSwift/OLEKit) (Swift) | Apache-2.0 | compound files and encrypted Office files, no text | No: `CompoundFile` already exists |
| PPTXKit (Swift, codelynx/pptx-swift) | not read | a viewer, by its description | Unchecked, no |
| [xlsxio](https://github.com/brechtsanders/xlsxio) (C) | MIT, needs expat and minizip | .xlsx rows as strings, streaming | No: a second ZIP and XML stack beside ZIPFoundation and XMLParser |
| [libxls](https://github.com/libxls/libxls) (C) | BSD-2-Clause | .xls (BIFF8); its README says it is fuzzed and since 1.5 returns errors and parses from memory | The only ready .xls reader; see below |
| [libgsf](https://github.com/GNOME/libgsf) (C, GLib) | LGPL 2.1 | OLE2 and ZIP | No: GLib on both platforms |
| LibreOffice filters and libetonyek (C++) | MPL-2.0, Boost | everything, Keynote 09 | No: MPL is not on the user's list, and the size is vast |
| Apache POI HSLF, XSLF, HSSF (Java) | Apache-2.0 | all four | Not shippable; useful as a map and as test files |

- Nothing permissive in Swift or C reads .pptx or .ppt (searched; absence is not proved).
- Apple's frameworks: `NSAttributedString` and `textutil` know plain, RTF, RTFD, HTML, Word 97 (`docFormat`), WordML, Word OOXML, OpenDocument text, and web archives; none is a slide or sheet format ([Apple's document types](https://developer.apple.com/documentation/appkit/nsofficeopenxmltextdocumenttype); Apple calls them maintenance-only in [a forum answer](https://developer.apple.com/forums/thread/832991)).
- Quick Look draws previews and thumbnails and gives no text API on either platform (unchecked in detail); Spotlight's importers give a flat blob and are Mac only (observed).

### Own parsers, weighed honestly

- **For:** the user's reason is the strongest one: reading order, alt text, hidden content, limits, and cancellation are all decisions of this app, and a library hands back its own model of them.
- **For:** every reader here runs on hostile input with no trap allowed. TextMouth's readers carry bounds-checked reads, a 64 MB limit, and cancellation hooks, and C code on the iPhone cannot be moved into the helper process the Mac uses for liblouis and FFmpeg.
- **For:** the precedent is unbroken: DOCX, ODT, RTF, Word 97, MOBI, KFX, TTA, WavPack, and Monkey's Audio are own readers, and the note on third-party code says they were written clean-room from the specifications.
- **For:** the formats are open. Microsoft publishes the standard's implementer notes ([MS-OI29500](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/)), the binary formats ([MS-PPT](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-ppt/cb3376a8-6bd6-4c62-b579-081eef2195b5), MS-XLS), and a patent notice that points to its Open Specifications Promise (verified on the MS-OI29500 page).
- **Against:** no copy of Office is available to write test files, so edge cases come from Apache POI's and LibreOffice's test files, which the repository already uses under their licences (observed).
- **Against:** an Excel number-format engine and a PowerPoint layout resolver are real work; a bug is silent wrong speech, not a crash.
- **Weighing:** for .pptx, .xlsx, .odp, .ods, and CSV the format core is XML or text, and an own reader is cheaper than adapting a library. For .xls, libxls would save about two weeks but not the date and number logic, and puts C in the process; the same argument as the other binary readers applies, so write it later, from MS-XLS, with libxls only as a map.
