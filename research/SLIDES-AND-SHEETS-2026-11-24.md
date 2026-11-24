# PowerPoint, Excel, CSV, and picture descriptions: research
<!-- research for the user's request of November 24, 2026; main 5a67ff468 (0.5.11); no code was changed -->

Part of [the research folder](README.md).
Marks used below: **verified** means a primary source was read this session; **observed** means seen in the repository or in a probe on files made for this report; **unchecked** means not confirmed.
The probes were short Python scripts in a scratch folder, run with a time limit on files built from XML text; none is committed.

## Summary

- TextMouth reads none of these formats today: .pptx, .xlsx, .csv, .tsv, .odp, and .ods are refused as unsupported, and Keynote and Numbers are refused with advice to export a PDF.
- Own readers over ZIPFoundation and `XMLParser`, about 1,000 to 1,500 lines a format, fit better than any library found, and run on the Mac and the iPhone alike; only .xls and .ppt need the compound-file reader, later.
- No permissive library reads .pptx or .ppt, CoreXLSX reads only .xlsx into memory, libxls runs C in-process, and Apple's frameworks read neither slides nor sheets.
- Slides: a page and a heading each, contents in z-order (PowerPoint's own screen-reader order) with the title first and footers out; an XY-cut over shape positions repairs a sloppy order.
- Sheets: a heading per visible sheet and a paragraph per row, cells joined by ", ", because TextMouth's table reading joins cells with one space, which is ambiguous in speech and braille.
- Excel stores no display text, so dates and percents need the number format and the 1900 or 1904 epoch (serial 45123 is 2023-07-16 or 2027-07-17); .ods stores the display text.
- Picture text is DrawingML `descr` and `title`, plus a `decorative` mark; Word, RTF, and Word 97 pictures are silent today (DR35), so one shared `PictureDescription` policy serves all.
- Order: picture policy with .docx, CSV, .xlsx and .ods, .pptx and .odp, charts and SmartArt, then .xls and .ppt; about 5,000 lines plus tests, no new library.
- Keep refusing Keynote and Numbers, but advise export to PowerPoint, Excel, or CSV once those are read.
- New `BookFormat` cases make this a 0.6.0 change by the version policy, with a changelog caution for older builds.

## Question 1: the formats and what TextMouth already has

- **PowerPoint:** .pptx, .pptm, .ppsx, .ppsm, .potx, .potm share one package layout, `ppt/presentation.xml` with `p:sldIdLst`; macro and template forms differ only by content type, as .docx and .dotx do (observed in `Book.swift`).
  Legacy .ppt, .pps, .pot are one compound file with a "PowerPoint Document" stream.
- **Excel:** .xlsx, .xlsm, .xltx, .xltm share `xl/workbook.xml`; legacy .xls (BIFF8) is a compound file with a "Workbook" stream (BIFF5 uses "Book", unchecked).
- **OpenDocument:** .odp and .ods are ZIPs with `content.xml`, like .odt.
- **CSV and TSV:** not read.
  `detect(from:)` gives nil for them, so the import says the format is unsupported (read from the code, not run).
  A .csv renamed .txt would read as plain text.
- **Keynote and Numbers:** not readable in practice (see below); both are refused today with a PDF-export sentence.
- **Compound-file format of .ppt and .xls:** `CompoundFile` already reads root streams by name with bounds-checked `OLEBytes` and loop guards; it was written for Word 97, and its header comment names legacy Excel and PowerPoint as users (observed).
- **Reusable as they are:**
  - ZIPFoundation with `ArchiveEntryLimits` (64 MB per text entry) and `DocumentByteLimit`.
  - `PackageSAXParser` and `OfficeXMLReader`: document type refused, 200-element nesting limit, cancellation checks.
  - `DOCXParser+Relationships` for relationship files, and `MarkdownPageMarker` with the `doc-pagebreak` route of `OwnDocumentReaders`.
- **Reusable with care:** `OfficeParagraph`, `OfficeBlockWriter`, and `RTFBlockBuilder` hold paragraphs, pages, lists, and tables for the ODT and Word 2003 XML readers; a slide reader can drive them through HTML as `ODTDocumentReader` does.
  `OfficeParagraph` is built around OpenDocument's white-space rules, so a DrawingML reader should write its paragraphs through the block builder directly.
- **Not reusable:** the DOCX converter writes Markdown directly and is 1,568 lines of Word-specific state; a PowerPoint reader copies its patterns (hidden text, `mc:AlternateContent`, cancellation), not its code.
- **Missing:** math.
  TextMouth reads no OMML equation in .docx, and KFX math is read as the words of its MathML (observed: `KFXWalk.accessibleName`).
  A shared OMML-to-words step would serve Word and PowerPoint.

## Keynote and Numbers

- Files made by Keynote and Numbers 2013 and later are ZIPs of Snappy-compressed protobuf `.iwa` files plus images.
- The protobuf definitions were extracted from the running apps, so new releases break parsers ([keynote-parser README][s1], verified by search result).
- The [SheetJS notes on IWA][s2] describe the block framing.
- The repository's Pages samples show both generations: `Pages_4.pages` holds `index.xml` and a preview PDF, and `Pages_5.pages` holds `Index/*.iwa` and only JPEG previews (observed).
- The first kind is XML that LibreOffice's libetonyek reads (MPL-2.0, C++, Boost: out of scope); the second has no spec.
- macOS ships `iWork.mdimporter` and `Office.mdimporter`, Spotlight plug-ins that index flat text.
  `mdimport -t` on a made deck returned a 429-character text blob and on a made workbook none (observed).
  They have no public API and no structure, and the iPhone has none (unchecked).
- **Verdict:** keep refusing.
  Once .pptx and .xlsx are read, change the advice to "Export Keynote presentations as PowerPoint" and "Export Numbers spreadsheets as Excel or CSV", which both apps do.

## Question 2: libraries or TextMouth's own parsers

### What exists

| Option | Licence | Reads | Verdict |
| --- | --- | --- | --- |
| [CoreXLSX][s3] (Swift) | Apache-2.0, needs XMLCoder and ZIPFoundation | .xlsx only; decompresses in memory; shared strings, styles, `dateValue`; its README does not mention formulas, merged cells, or hidden rows (verified) | No: no streaming, no .pptx, no .xls |
| [OLEKit][s4] (Swift) | Apache-2.0 | compound files and encrypted Office files, no text | No: `CompoundFile` already exists |
| [xlsxio][s5] (C) | MIT, needs expat and minizip | .xlsx rows as strings, streaming | No: a second ZIP and XML stack beside ZIPFoundation and XMLParser |
| [libxls][s6] (C) | BSD-2-Clause | .xls (BIFF8); its README says it is fuzzed and since 1.5 returns errors and parses from memory | The only ready .xls reader; see below |
| [libgsf][s7] (C, GLib) | LGPL 2.1 | OLE2 and ZIP | No: GLib on both platforms |
| LibreOffice filters and libetonyek (C++) | MPL-2.0, Boost | everything, Keynote 09 | No: MPL is not on the user's list, and the size is vast |
| Apache POI HSLF, XSLF, HSSF (Java) | Apache-2.0 | all four | Not shippable; useful as a map and as test files |

- Nothing permissive in Swift or C reads .pptx or .ppt (searched; absence is not proved).
  A Swift viewer, PPTXKit, was found and not checked.
- Apple's frameworks: `NSAttributedString` and `textutil` know plain, RTF, RTFD, HTML, Word 97 (`docFormat`), WordML, Word OOXML, OpenDocument text, and web archives; none is a slide or sheet format ([Apple's document types][s8]; Apple calls them maintenance-only in [a forum answer][s9]).
- Quick Look draws previews and thumbnails and gives no text API on either platform (unchecked in detail); Spotlight's importers give a flat blob and are Mac only (observed).

### Own parsers, weighed honestly

- **For:** the user's reason is the strongest one: reading order, alt text, hidden content, limits, and cancellation are all decisions of this app, and a library hands back its own model of them.
- **For:** every reader here runs on hostile input with no trap allowed.
  TextMouth's readers carry bounds-checked reads, a 64 MB limit, and cancellation hooks, and C code on the iPhone cannot be moved into the helper process the Mac uses for liblouis and FFmpeg.
- **For:** the precedent is unbroken: DOCX, ODT, RTF, Word 97, MOBI, KFX, TTA, WavPack, and Monkey's Audio are own readers, and the note on third-party code says they were written clean-room from the specifications.
- **For:** the formats are open.
  Microsoft publishes the standard's implementer notes ([MS-OI29500][s10]), the binary formats ([MS-PPT][s11], MS-XLS), and a patent notice that points to its Open Specifications Promise (verified on the MS-OI29500 page).
- **Against:** no copy of Office is available to write test files, so edge cases come from Apache POI's and LibreOffice's test files, which the repository already uses under their licences (observed).
- **Against:** an Excel number-format engine and a PowerPoint layout resolver are real work; a bug is silent wrong speech, not a crash.
- **Weighing:** for .pptx, .xlsx, .odp, .ods, and CSV the format core is XML or text, and an own reader is cheaper than adapting a library.
  For .xls, libxls would save the record parsing but not the date and number logic, and puts C in the process; so write it later, from MS-XLS, with libxls only as a map.

## Question 3: PowerPoint for listening

### Slides, pages, and headings

- The slide order is `p:sldIdLst` resolved through `ppt/_rels/presentation.xml.rels`, never the file names (observed in the pandoc sample).
- Each slide is a page, labelled with its position (plus `firstSlideNum` minus one when the presentation sets it; unchecked), through the `<!-- page: N -->` marker that every reader of pages writes.
- A hidden slide (`<p:sld show="0">`) keeps its number, so skipping it leaves a gap in the labels (3, then 5) that tells the listener something was left out.
- The slide's heading is its title placeholder (`type="title"` or `ctrTitle`); a slide with none is headed "Slide N" and never guessed from the biggest text.
- Sections (`p14:sectionLst` in `presentation.xml`'s extension list, unchecked) would be level-1 headings above the slides' level-2 headings; without sections, slide headings are level 1.
- Speaker notes sit in `ppt/notesSlides`; only the `body` placeholder is read, and `sldImg` and `sldNum` are skipped (observed in the pandoc sample, where slide 3 has notes).
- Notes are read after the slide, led by a short localized word, and by a setting they can be left out.
- Comments (legacy `ppt/comments/*.xml`; modern comments in per-slide parts with one authors part, per [Microsoft][s12] and the [Open XML SDK's p188 names][s13]) are skipped, as comments are in .odt.
- A hyperlink keeps its text and never its address, as everywhere.

### The order PowerPoint speaks

- **The standard:** the shape tree's lexical order is z-order, back to front, and it is also the navigation order, so the first shape is first ([ISO 29500-1 on `p:spTree`][s14], verified).
- **Windows:** the Reading Order pane lists objects in the order a screen reader reads them, top to bottom ([Microsoft][s15], verified).
- **Selection pane:** it lists the same objects front to back, so a reader goes from its bottom to its top ([Section508.gov][s16], verified).
  On a Mac, Microsoft says screen readers read "the reverse of the order they are listed in the Selection Pane" ([Microsoft][s17], verified).
- **So** file order is the author's reading order, and a screen reader on a deck nobody checked reads shapes in the order they were made.
- **The checker:** Microsoft's Accessibility Checker flags a slide when the order "doesn't match one of the common ways objects are spatially ordered" (verified): the order and the page's positions are expected to agree.
- **Decorative objects** are skipped in a show (verified); hidden objects stay in the Selection pane and are still read (Section508.gov, verified).

### Reading order for TextMouth: three rules

1. **Collect the leaves in tree order.**
   A group is entered in place, its children in the group's own order; a table, a chart, a diagram, and a picture are each one leaf.
2. **Put the title first and the furniture out.**
   The title placeholder is read first whatever its z-order.
   Date, footer, and slide-number placeholders are dropped, since they repeat on every slide.
3. **Repair the order from the positions, but only when the author's order is out of step.**
   The positions come from the shape's `a:xfrm`; a placeholder without one takes it from the layout's placeholder with the same `idx` (or `type`), then the master's.
   The order is the recursive XY-cut: split the shapes at the widest empty horizontal gap, else at the widest empty vertical gap, and recurse; columns go right to left when the slide's text is right to left.
   The repair applies when the author's order matches neither row-major nor column-major order of the positions (the "common spatial orders"); a deck the author fixed by hand in the Reading Order pane normally matches one.
   This test is a proposal: the probe printed both orders and chose none, so the threshold needs real decks.
- A setting, "Order of slide contents", offers Smart (the default), As the author set it, and By position always; it is applied at import, so changing it reads the book again.
- Failure modes of the position rule: overlapping shapes and diagrams with arrows have no clean gap, and the cut falls back to top-to-bottom, left-to-right; a callout the author deliberately read last is moved.

### Worked examples (probe on made slides)

Slide 1, title added last, footer note first, content placeholder with no position of its own:
```
author order : Footer note > Content > Title
title first  : Title > Footer note > Content
by position  : Title > Content > Footer note      (Content placed by the layout's idx 1)
```
Slide 2, right column made first, a callout, a title placeholder, and a footer placeholder:
```
author order : Right column > Left column > Callout > Title > Page footer
by position  : Title > Callout > Left column > Right column > Page footer
```
- The author's order on slide 2 reads "what to pack" before "where to go", which is what a screen reader following the file's order says; the repair reads the title, the callout above the columns, then left, then right.
- The shapes of slide 1 had no `a:xfrm` of their own; without the layout lookup the content would have no position at all (observed: a probe that resolves `idx` through `slideLayout1.xml`).

### Each kind of object

- **Text boxes and WordArt:** a `p:sp` with a `txBody` is its paragraphs; WordArt is the same text under a `prstTxWarp` and is read as plain text.
- **Bullets and levels:** a paragraph's `lvl` is its list level.
  In a body or object placeholder a paragraph is a list item unless `a:buNone` is in effect, which comes from the slide, then the layout placeholder's `lstStyle`, then the master's `bodyStyle` (unchecked: the exact cascade).
  A numbered level has `a:buAutoNum`.
  The pandoc sample writes `buNone` on every paragraph.
- **Columns:** `numCol` on `a:bodyPr` lays one text body out in columns, but the XML order is already the reading order; no action.
- **Tables:** `a:tbl` rows are read as paragraphs through the same table builder as sheets (see Question 4); the header row is `firstRow="1"`; a cell covered by a merge (`hMerge`, `vMerge`) is skipped and the covering cell speaks once (observed in the probe).
  A table's `descr` is read before it as its description.
- **Charts:** a chart is a graphic frame whose data is in `ppt/charts/chartN.xml`.
  Read its alt text first; if there is none, its title, its axis titles, and each series' name with its cached categories and values, which are stored in the file (`c:cat`, `c:val` caches; unchecked in a sample, since none was made).
- **SmartArt:** the diagram has a data model (`dgm:pt` nodes with text, `dgm:cxn` parent links) and a cached drawing of the laid-out shapes, named by the `dataModelExt` relationship id ([MS-ODRAWXML][s18], partly verified by search result).
  Read the data model as a nested list, the node depth being the level; use the cached drawing's text when the model is empty.
- **Equations:** an equation is `a14:m` holding OMML inside `mc:AlternateContent`, with a picture as fallback.
  Read the choice, not the fallback, as the DOCX reader does for text boxes; the words need the shared OMML step noted in Question 1 (unchecked: the exact PowerPoint wrapping).
- **Groups:** read in place; a group is also a unit for the position order, with the box of its extents (the probe maps child boxes through `chOff` and `chExt`).
- **Text direction:** a paragraph's `rtl="1"` and a body's `vert` are display properties; the logical text order in the file is already the reading order, so the text is not reordered.
  Only the order between shapes changes (right to left when the slide is right to left, and for `eaVert` boxes, whose columns run right to left).
  The probe's Arabic title and vertical Japanese box read in logical order.
- **Unreadable:** a video, audio, ink, or 3-D model is silent, except for its alt text, and an embedded OLE object is its alt text.

### What the file says about layout

- **Positions** (`a:off`, `a:ext` in EMUs, 914,400 to the inch) give the position order.
  **Placeholder types** (`title`, `ctrTitle`, `subTitle`, `body`, `dt`, `ftr`, `sldNum`, `pic`, `chart`, `tbl`) say what a shape is.
  **Z-order** is the author's order.
- The layout and master supply what a slide's placeholder leaves out: position, and bullet and level styles.
  A slide shows a date, footer, or number only if it holds its own placeholder of that type (unchecked), so the layout's furniture never needs reading.
- **Slide 3 of the probe** has a group, a table with a merged row, and five pictures; it reads:
  - the title, then "Picture: A harbour wall at low tide, with weed on the steps.";
  - the decorative picture skipped, and a picture described only by "image1.png" skipped;
  - "A bar chart of tide heights", with Office's "Description automatically generated with medium confidence" suffix removed;
  - a picture with no description silent, then "Step one" and "Step two", and the table as rows.

## Question 4: Excel for listening

### The form

- **Not a pipe table.**
  `MarkdownParser.readTable` reads each row as a paragraph with cells "separated by one space" (observed), so "Alder Quay 4.2 0.6" cannot be split into cells by ear or by a braille display.
- **Not literal CSV.**
  Quotes and doubled quotes are escapes for a program; a voice may read them, and a braille line would show them.
- **Recommended:** a heading for each visible sheet, then one paragraph for each non-empty row with the cells joined by ", ", as the user approved for sheets and CSV in the October 17 questions (question 15, "yes for now").
- **Why commas:** a voice pauses at one, and a braille display shows an unambiguous cell border.
  The cost is a cell that holds a comma, which is rare in numbers and short labels.
- **Empty cells** inside a row stay as empty slots (`Ann, , 26%`), so a column keeps its place; trailing empties and fully empty rows are dropped.
- **Header names, as an option:** "Date 2023-07-16, Name Ann, Share 26%", chosen when a book is read and changed in Book Information, like the text encoding pop-up (FMT16); the first row of the sheet, or an Excel table's `headerRowCount`, supplies the names.
- **Merged cells** (`mergeCells`) speak once, from their top-left cell; the covered cells are skipped.
  A merged heading above the data reads as a one-cell row (observed).
- One table builder serves CSV, sheets, and the slide tables of Question 3, so the three read alike.
- **Pages:** a sheet is a heading, not a page (Question 9).

### The cells (probe on a made workbook)

```
date system: 1900                                   date system: 1904 (same cells)
--- sheet "Log"  (merged A1:C1)                     Date 2027-07-17, Name Ann, Share 26%
    Merged heading
    Date,Name,Share
    2023-07-16,Ann,26%      <- serial 45123, format 14
    (hidden row 4 dropped)
    1900-02-28,error #DIV/0!,#DIV/0!   <- serial 60
--- sheet "Scratch" skipped (hidden)
```
- **Strings:** a cell is a shared string (`t="s"`, its runs joined and phonetic `rPh` text dropped; unchecked), an inline string, a formula's string (`t="str"`), a boolean (TRUE or FALSE), an error (read as its text, "#DIV/0!"), or a number.
- **Formulas:** the cached `<v>` is read; the formula is never spoken.
  A formula with no cached value (a file a program wrote without calculating) is empty.
- **Dates:** a number is a date when its style's number format is one of the built-in ids 14 to 22 or 45 to 47 ([ISO 29500 list][s19], verified), or a custom code (id 164 and up) with a date letter outside quotes, brackets, and escapes; the `[$-409]` locale prefix and `[h]` elapsed forms need care.
- **Epochs:** `workbookPr date1904="1"` shifts every date by 1,462 days; the same 45123 is 2023-07-16 or 2027-07-17 (observed).
  Excel's 1900 system counts a 29 February 1900 that never existed: the usual base of 30 December 1899 is right from serial 61, a reader must use 31 December 1899 below 60, and serial 60 has no true date (the probe printed 1900-02-28 for it, a day early).
- **Spoken form of a date:** a long date in the interface language ("July 16, 2023") reads better than ISO digits; this is Question 7.
- **Numbers:** the file holds only the raw value, never Excel's display string, so "0%" on 0.255 needs a number-format engine: General, fixed decimals, thousands separators, percent, currency, and scientific cover most cells, and anything else falls back to General.
- General shows at most 11 digits and then exponential form (ISO 29500, verified), so a raw `0.30000000000000004` must not be spoken.
  Rounding must be half away from zero, as Excel does; a binary `printf` can differ on 25.5 (unchecked).
- **OpenDocument sheets** keep the display text in each cell's `text:p` beside `office:value` and `office:date-value`, so .ods needs no format engine (observed in the repository's sample; the cell and repeat rules are from the format, unchecked here).

### Hidden things, size, and the rest

- **Hidden sheets** (`state="hidden"` or `veryHidden`), **hidden rows and columns** (`hidden="1"`, which also covers filtered and collapsed rows) are skipped, by the rule the DOCX and ODT readers state: read what a person sees in the ordinary view.
  The probe dropped them.
- A line such as "3 hidden rows left out" is possible, but the existing readers say nothing for hidden text, so the recommendation is silence (Question 8).
- **Size:** parse each sheet as a stream with `XMLParser`, as DOCX does, never building a grid.
  Cells go in a sparse row, never an array sized by the column letters: a hostile `r="ZZZZZ1"` would allocate.
  Refuse column letters of more than three and rows past 1,048,576, the sheet limits.
- **Limits already there:** 64 MB per XML part (`ArchiveEntryLimits`) and per document (`DocumentByteLimit`).
  The `<dimension>` is a claim, not a limit; and an ODS row repeated a million times must be capped, as the October 17 notes say.
- **A proposed cap:** 100,000 rows read per sheet, then a closing sentence, "The sheet continues; this reading stops here", localized.
  A million-row sheet is not listenable, and the page and heading commands still reach every sheet.
- **Charts and drawings** on a sheet are read after its rows as in Question 3 (alt text, title, series); a chart sheet (`xl/chartsheets`) is the same.
- **Comments:** legacy notes (`xl/comments*.xml`) and threaded comments (whose fallback text is boilerplate, unchecked) are skipped, as Word's comments are.
- **Encrypted workbooks** are compound files with an `EncryptedPackage` stream; they and sheet-protection passwords (which only hash a password and never encrypt) are the password report's matter, not this one.
  A protected sheet reads freely.
- **Strict OOXML** uses other namespaces (`purl.oclc.org/ooxml`); a reader that takes only the transitional ones reads nothing from a Strict file (unchecked here; a fixture is cheap).

## Question 5: picture descriptions in every format

`imageresearch` covers describing a picture by machine; this section covers only what the files already say and what to do with it.

### Where each format keeps the description

| Format | Where the description is | What TextMouth does today |
| --- | --- | --- |
| HTML, EPUB, Markdown | `alt` (empty `alt=""` marks decoration) | read as words in the flow (observed: `HTMLToMarkdownConverter`, `HTMLReadingText`) |
| DAISY | `img` `alt` | written as `![alt](src)` and read as words; captions and `prodnote` unchecked |
| MOBI, KF8, KFX | `alt`, or KFX's alt text | read as words; none is silent (docs: "a picture without one is silent") |
| OpenDocument text | `svg:desc`, else `svg:title` on the frame | its own paragraph after the anchor's paragraph; none is silent (observed: `ODTContentReader.readDescription`) |
| Word (.docx) | `descr` and `title` on `wp:docPr` and `pic:cNvPr`; VML `alt` | silent (issue DR35, question unanswered) |
| Word 97 (.doc) | the Escher shape property `wzDescription`, id 0x0381 ([MS-ODRAW][s20], verified) | silent |
| RTF, Word 2003 XML | `\sp` shape properties; `wp:docPr` equivalents in WordML (unchecked) | silent |
| PowerPoint, Excel | `descr` and `title` on `p:cNvPr` and `xdr:cNvPr`; the decorative mark below | not read at all |
| PDF | `/Alt` on a tagged Figure ([WCAG PDF1][s21]) | not read; whether PDFKit exposes the structure tree is unchecked |

### The decorative mark

- A picture is decorative when its `cNvPr` carries a `decorative` element with `val="1"`, in the namespace `http://schemas.microsoft.com/office/drawing/2017/decorative`.
- The [MS-ODRAWXML schema][s22] gives the element and its boolean `val` (verified); the extension URI `{C183D7F6-B498-43B3-948B-1728B52AA6E4}` that wraps it is the one the probe used (unchecked).
- The Reading Order pane drops such an object from the order ([Microsoft][s15], verified), so a reader that skips it agrees with what PowerPoint's screen readers do.
- A `descr` that is empty, or a picture with no `descr`, is silent.

### A policy for every format

1. **One type, `PictureDescription`,** takes the raw `descr` or `alt` and `title` and returns the words to speak, or nothing.
   Every reader calls it, so the rules live once.
2. **Order:** description, else title, as `ODTContentReader` does now.
3. **Cleaning:** collapse white space and remove Office's machine suffix "Description automatically generated".
   The suffix is real, per [Clemson][s23]; its "with low, medium, or high confidence" tail is from memory (unchecked).
   A value that is only a file name (`image1.png`, `IMG_0042.JPG`) or an unedited default (`Picture 3`) counts as no description.
4. **Silent** for decorative, empty, or default descriptions, so a picture that says nothing adds nothing.
5. **Marked:** where nothing else in the reading says what the words are (a slide, a sheet, and the formats that are silent today), the paragraph begins with a short localized lead, "Picture: ", so a listener or a braille reader knows a description from a sentence of the text.
6. **Where:** as its own paragraph right after the paragraph that holds the picture (the ODT precedent), or in the shape's place on a slide.
7. **Not changed:** existing readers' bare alt text.
   Adding a lead there changes saved text and positions; Question 10 asks whether to do it anyway.
- **Order of work:** the type and its tests first, with .docx (DR35's cheapest part; the description is in plain view of the converter), then each new reader.
- **No description at all:** silent, as now.
  A machine description would fill that gap; `imageresearch` owns it, and `PictureDescription` is the one place it would plug in.

## The options compared

| Choice | Reading control | Both platforms | Safety on hostile files | Cost | Verdict |
| --- | --- | --- | --- | --- | --- |
| Own readers over ZIPFoundation and `XMLParser` | total | one code base | Swift bounds checks, existing guards | about 1,000 to 1,500 lines a format | Yes for .pptx, .xlsx, .odp, .ods, CSV |
| Own readers over `CompoundFile` | total | one code base | `OLEBytes` bounds checks | about 900 to 1,000 lines each | Yes, later, for .ppt and .xls |
| libxls plus own date and number logic | cell values only | C on the iPhone, no helper process | fuzzed, but in-process | about 400 lines of glue | Only if .xls is wanted soon and the user accepts C |

## Recommendation

- Write own readers, in the order of the plan below, sharing three pieces: an OPC package helper, a table builder, and `PictureDescription`.
- Write Markdown directly, as DOCX does, since sheets and slides are paragraphs and not HTML tables.
- Read slides in z-order with the title first and the furniture out, and repair the order from positions only when the author's order is out of step with them.
- Read sheets as a heading per visible sheet and a ", "-joined paragraph per row, with the cell's own display text, dates in words, and hidden things left out.
- Fix the silent pictures of Word and the formats beside it with the same type, and say "Picture: " before a description where nothing else marks it.
- Refuse Keynote and Numbers, and say to export PowerPoint, Excel, or CSV.
- Use no API beyond the DOCX and ODT readers' (`XMLParser`, ZIPFoundation) and `DateFormatter` for spoken dates, all present on macOS 14 and iOS 26, so a Mac on 14 or 15 reads the same.

## Plan in phases

Every phase is Mac and iPhone together, since the readers are shared Swift with no AppKit; the iPhone's half is only the document types in its `Info.plist` and the refusal list.
Sizes are estimates of Swift source, with tests about the same again.

1. **Picture policy and .docx (0.5.x, about 350 lines).**
   - `PictureDescription`, the `descr` read in the DOCX converter, and the table in Question 5 as tests; this is DR35's cheapest part. iPhone: nothing more.
   - Tests: made `.docx` files in the existing generator style, with a description, a title, decorative, empty, a file name, and a Microsoft suffix.
2. **CSV and TSV (FMT15, about 400 lines).**
   - A state machine for quotes and line breaks, the delimiter sniffed from the first rows (comma, semicolon, tab, pipe), and `TextFileDecoder` for the encoding, so CSV joins the formats of the Text Encoding pop-up; plus the table builder and the row cap.
   - Tests: the repository's `csv/books.csv`, a semicolon file, a BOM, Excel's `sep=;` first line, CRLF, a quoted newline, a ragged row, and a million-row file made by a test.
3. **.xlsx family and .ods (FMT35, half of FMT36, about 1,300 lines).**
   - Workbook and relationships, shared strings, styles with the date and number engine, streaming sheets, merged and hidden cells, 1904, Strict namespaces, and the sparse row; the ODS reader on `ODTXMLReader`.
   - Tests: workbooks generated from XML text (the probe's shape) with each rule above as a case, hostile cases (huge references, a repeated-row bomb, a ZIP bomb, deep nesting), and the repository's two inventory samples.
4. **.pptx family and .odp (FMT33, half of FMT36, about 1,500 lines).**
   - Slides, layout and master geometry, the order rules, tables, notes, hidden slides, alt text, bullets, groups, and `a14` equations as text; the ODP reader over `draw:page`.
   - Tests: the probe's slides as fixtures (the worked examples above are the expected output), the pandoc `pptx/tides.pptx`, an RTL slide, a vertical-text slide, a loop in the layout relationships, a deep group, and each order mode.
5. **Charts, SmartArt, and the OMML words (about 600 lines).**
   - A chart's title, axes, and series; a diagram's nested list; equations spoken for Word and PowerPoint.
   - Tests: made chart and diagram parts, and Apache POI's and LibreOffice's real files where the licence allows.
6. **Legacy .xls and .ppt (about 1,000 and 900 lines, from MS-XLS and MS-PPT).**
   - The records are bounds-checked `OLEBytes` reads over `CompoundFile`.
     BIFF8 needs its shared string table with continuation records, number and RK cells, cached formulas, date formats, 1904, and hidden rows.
   - A .ppt needs the `SlideListWithText` records, each `SlidePersistAtom` with its slide's texts in order, and the `TextCharsAtom` (UTF-16) and `TextBytesAtom` (one byte a character) records ([MS-PPT][s24]).
   - Tests: a compound-file writer in test support with hand-built records, and POI's and LibreOffice's real files.
7. **Advice and documents.**
   - The Keynote and Numbers sentences, `formats-list.md`, the "what TextMouth reads" pages, and the changelog caution for the new `BookFormat` cases (raw values `presentation` and `spreadsheet`; older builds open a library without those books).

### Sizes and strings

- Machine code for the readers is a rough 100 to 200 KB in each app (an estimate, unmeasured); no library or licence folder is added.
- Interface text is small: "Slide N: title", "Picture: ", "Notes", two format names, and a few settings and refusal lines, each translated into the 24 languages before its branch merges.
- Each extension needs `Info.plist` document and uniform types in both apps.

### Fixtures: what can and cannot be made here

- **Can be made:** every .pptx, .xlsx, .odp, .ods, and CSV case, by a script or test helper that writes XML text into a ZIP, as the repository's `scripts/documents/make_text_samples.py` does and the probe here did (the one existing .pptx came from pandoc, which macOS does not ship).
- **Can be made with code TextMouth holds:** .ppt and .xls, by a compound-file writer and record builders in test support.
- **Cannot be made without Office or iWork:** files as Office really writes them (Strict mode, extension lists, real charts with caches, SmartArt, threaded comments, edited reading orders) and any Keynote or Numbers file.
- Apache POI's and LibreOffice's test files stand in for those, and the user's own decks and workbooks would be the best test (Question 15).

## Risks

- **No Office to compare with.**
  A number-format or layout bug is silent wrong speech, so each rule needs a real file from POI or the user before it is called tested.
- **The order repair can be wrong.**
  A deck whose odd order was deliberate is reordered; the setting and the "author's order" mode are the escape.
- **Saved places.**
  A change of reading mode or version re-reads a book, and must keep the listener's place the way the pages re-read does.
- **Hostile input:** cell references, repeated rows, nested groups, relationship loops, giant `dimension` claims, and ZIP bombs; each is a named test.
- **Spoken dates and numbers** differ by language and voice (Question 7).
- **New `BookFormat` cases** make older builds drop these books from an opened library, so the changelog must say so.
- **Patents:** Microsoft's notice says its Open Specifications Promise may not cover every case and offers a written licence (verified on the MS-OI29500 page); this already holds for .docx and .doc.

## Questions for the user

Each has the answer I recommend.

1. **Formats in the first release:** .pptx, .xlsx, CSV, TSV, .odp, and .ods, with .ppt and .xls later.
   Recommended: yes.
2. **Slide headings:** "Slide 3: Reading the chart", or the title alone with "Slide N" for an untitled slide?
   Recommended: with the number.
3. **Order of slide contents:** Smart, As the author set it, or By position always?
   Recommended: Smart by default, with the setting.
4. **Speaker notes:** read after each slide, with a setting to leave them out?
   Recommended: read by default.
5. **Hidden slides:** skipped, keeping their numbers?
   Recommended: skipped, with a setting.
6. **Row form:** ", "-joined cells, with column names as an option in Book Information?
   Recommended: yes.
7. **Dates:** spoken as a long date in the interface language?
   Recommended: yes.
8. **Hidden rows, columns, and sheets:** left out in silence?
   Recommended: yes.
9. **Is a sheet also a page,** labelled by its name?
   Recommended: no; slides only.
10. **A "Picture: " lead:** for the new readers and the formats silent today only, or also added to HTML, EPUB, and ODT, which shifts their saved text?
    Recommended: new and silent formats only.
11. **A picture with no description:** stay silent until `imageresearch`'s answer lands?
    Recommended: yes.
12. **Row cap:** 100,000 rows a sheet, with a spoken closing line?
    Recommended: yes.
13. **Comments in Excel and PowerPoint:** skipped, as Word's are?
    Recommended: skipped.
14. **Keynote and Numbers:** keep refusing, and change the advice to PowerPoint, Excel, or CSV once those are read?
    Recommended: yes.
15. **Sample files:** will you give a few decks and workbooks you do not mind sharing, in a folder you name, for tests?
    I never open your files; an agent could then compare.
    Recommended: yes.
16. **Version:** 0.6.0, since the format list grows?
    Recommended: yes.

## Sources

[s1]: https://github.com/psobot/keynote-parser

[s2]: https://git.sheetjs.com/sheetjs/notes/raw/commit/e7bc6809cd292eccd5467ab218d46edc013f2429/iwa/README.md

[s3]: https://github.com/CoreOffice/CoreXLSX

[s4]: https://github.com/PureSwift/OLEKit

[s5]: https://github.com/brechtsanders/xlsxio

[s6]: https://github.com/libxls/libxls

[s7]: https://github.com/GNOME/libgsf

[s8]: https://developer.apple.com/documentation/appkit/nsofficeopenxmltextdocumenttype

[s9]: https://developer.apple.com/forums/thread/832991

[s10]: https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/

[s11]: https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-ppt/cb3376a8-6bd6-4c62-b579-081eef2195b5

[s12]: https://support.microsoft.com/office/modern-comments-in-powerpoint-c0aa37bb-82cb-414c-872d-178946ff60ec

[s13]: https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.office2021.powerpoint.comment

[s14]: https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.presentation.shapetree?view=openxml-3.0.1

[s15]: https://support.microsoft.com/en-US/PowerPoint/make-slides-easier-to-read-by-using-the-reading-order-pane

[s16]: https://www.section508.gov/blog/accessibility-bytes/presentation-reading-order/

[s17]: https://support.microsoft.com/en-us/office/make-your-powerpoint-presentations-accessible-to-people-with-disabilities-6f7772b2-2f33-4bd2-8ca7-dae3b2b3ef25

[s18]: https://learn.microsoft.com/en-us/openspecs/office_standards/ms-odrawxml/44da4385-43e1-4c9e-9061-71557d17155a

[s19]: https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.numberingformat?view=openxml-3.0.1

[s20]: https://msdn.microsoft.com/en-us/library/3fcb6cc3-b8c2-481b-aa47-078898d87c78

[s21]: https://www.w3.org/WAI/WCAG22/Techniques/pdf/PDF1

[s22]: https://learn.microsoft.com/en-us/openspecs/office_standards/ms-odrawxml/6146d89f-9146-415b-99e2-39e694b5a980

[s23]: https://clemson.edu/accessibility/digital/guides/powerpoint/images.html

[s24]: https://msdn.microsoft.com/de-de/library/dd772921(v=office.14)
