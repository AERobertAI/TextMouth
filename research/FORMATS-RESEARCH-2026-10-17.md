# New formats and export: research (October 17, 2026)

A design note for the TODO's new section, "New formats and export (researched October 17)", items FMT01 to FMT51, written before anything is built. It draws on the code on main at 8b4d94c8, on six research workers (Sonnet, one per family of formats) and the lead's own checks, and on primary sources: specifications, Apple's documentation, SDK headers and manual pages, the formats' own sites, and the libraries' own repositories and licence files. Nothing in the app was changed. Every probe ran on files made on this Mac; every download was inspected only with `file`, `shasum`, and its size, and read only by `python3 -I`; nothing played a sound.

The request, in the user's words (October 17, 2026): "I was thinking it might be nice to add more format support to TextMouth, I put a file of some other AI instants responses of the question on what we should add maybe not everything but I think it would be nice if at least we could convert a bunch more audio formats to a standardized format like how we convert the text files to markdown and then maybe for another feature in the todo allow "exporting" any book (text or audio) to any other support format, giving the option to export part of a text book as audio too in one of the available formats... for text I am especially interested in adding rtf, dot, .doc, and braille .brf / .brl files (writing the encoder and a decoder for this as well)..." Then: "also if the agent team can try finding sample files for the new wanted formats to preparie for testing..."

The file of other assistants' answers (`HumanFiles/aiThinkingAboutFormats.txt`, from ChatGPT, Gemini, and Claude) was weighed claim by claim; section 8 says which claims hold.

## Summary

- **The user's text formats, RTF, .doc, and .dot, can be read soon and cheaply.** Apple's `/usr/bin/textutil` reads all three by their content (a .dot exactly as a .doc), and RTFD, ODT, OTT, WordML, and Word's newer templates too, in 0.04 to 0.16 seconds for ordinary files and about a second for a 3.3 MB RTF. Run as a child process under the same watchdog as the Ogg converter, its HTML goes to TextMouth's existing HTML-to-Markdown converter (FMT13). The catch, verified: every heading comes back as a bold, larger paragraph, never as a heading, so TextMouth would find chapters by font size. Readers of the real heading styles are an L for later, if the font sizes fail (FMT47). The newer .dotx, .docm, and .dotm already open with TextMouth's own Word reader once their extensions are listed (FMT01).
- **Braille: decoding cells is easy, contracted braille needs a translator.** BRF and BRL are the same 64-character North American Braille ASCII (BRL unformatted), mapped to Unicode braille by a fixed table. Turning contracted (Grade 2) braille, the kind BARD and Bookshare deliver, into print, and print into Grade 2, needs a translator: liblouis is the standard (LGPL 2.1 or later, about 0.5 to 0.7 MB with the English tables, buildable from source as LAME is). macOS 26 ships liblouis privately for VoiceOver and adds a public translator API, `AXBrailleTranslator`, which offered a test program no tables at all (verified); a short spike inside an app decides whether it can stand in on macOS 26. The plan: read BRF, BRL, and PEF with TextMouth's own Grade 1 decoder (FMT20), add liblouis for Grade 2 (FMT21), and export to BRF and PEF (FMT22). macOS 26's Braille Access already shows a BRF's cells exactly; TextMouth's part is speech, the library, navigation by page and heading, and export.
- **Audio's standard form: AAC in .m4a for lossy sources, Apple Lossless in .m4a for lossless ones.** This is to audio what Markdown is to text. macOS already decodes AC-3, E-AC-3, AMR, MP2, 3GP, CAF, AIFC, .au, Wave64, and RF64 (verified on files made here): only the extensions and a watched conversion are missing (FMT09). WMA, WavPack, TTA, APE, Speex, Musepack, and Matroska or WebM need ffmpeg. The ffmpeg the user installed with Homebrew, which TextMouth's audio editor already finds, includes Apple's own AAC encoder (`aac_at`), so one watched run converts a file and keeps its chapters (FMT31, FMT32). A bundled ffmpeg would add an estimated 1.5 to 3 MB and a source obligation (FMT50).
- **Export: a Convert to choice in the existing Export dialog** (FMT18) opens the way to HTML, RTF, EPUB 3, DOCX, ODT, BRF, PEF, and audio in another format. Apple's writers drop every heading style in DOCX, ODT, and RTF (verified), so TextMouth writes those itself; prototypes passed EPUBCheck and read back with their headings in pandoc. **Text to audio** renders the reader's own text with `AVSpeechSynthesizer.write`, which the speech engine already uses, into a chapter file per heading, then through the audio editor's existing encoders: M4B, M4A, or MP3 with a chapter per heading (FMT43, FMT44). With `say -o` as a proxy, the voices render 18 to 128 times faster than real time, so a 10-hour book would take about 5 to 35 minutes and 1.6 GB of temporary disk. Apple's licence allows audio made with the Mac's voices for personal, non-commercial use only.
- **Companions:** a podcast episode's own transcript and chapters, whose Podcasting 2.0 links TextMouth stores and never fetches, is the most valuable item of that family (FMT25, after SRT and WebVTT, FMT23). CUE sheets give headings to one-file audiobooks (FMT24), and M3U playlists open collections made elsewhere (FMT10). M4B files whose chapters are only a Nero `chpl` list show no headings today (verified; FMT05).
- **Other documents:** pictures of pages through the Vision text recognition that already reads scanned PDF pages (FMT34), CSV (FMT15), PowerPoint (FMT33), and email (FMT45).
- **Refused, with advice:** Pages, Keynote, Numbers, WordPerfect, CHM, DjVu, XPS, RAR comics, and copy-protected audio get a sentence saying how to convert them (FMT02).
- **Size and safety:** nothing recommended adds more than about 0.7 MB (liblouis), except an optional bundled ffmpeg. Every new decoder of untrusted bytes that Apple handles poorly runs in a child process under `WatchedProcess`, the October 14 rule.
- **Samples:** 148 files, 3.45 MB, in `TestData/format-samples/`, one folder per format, listed in `samples.tsv` (section 9).
- **Twenty-one questions** end the document (section 12).

## Difficulty and impact

- **S:** up to about 150 lines of Swift besides tests, no new library; about a day.
- **M:** about 150 to 500 lines, or a new import or export path through pieces that exist.
- **L:** about 500 to 1,000 lines, a new library or helper, or a new playback path.
- **XL:** more than that, or an undocumented format.
- **Impact** is for this user, 1 to 5: how often such files would reach a blind reader of books, podcasts, and audiobooks, and how much opening them matters.
- The TODO orders items from the easiest to the hardest; an item that needs another comes after it.

## 1. What TextMouth reads and exports today

Verified on main at 8b4d94c8.

- **Formats** (`Models/Book.swift`, `BookFormat`): EPUB; plain text; Markdown; HTML; Word .docx; DAISY 2.02 and 3; PDF, with Vision text recognition for scanned pages; and audio: MP3, M4A, M4B, WAV, AIFF, FLAC, ALAC, AAC, Ogg Vorbis and Opus (converted to AAC at import by `afconvert` in a watched child process), and the sound of MP4, M4V, and MOV video. A ZIP or folder of tracks becomes one book, ordered by an optional manifest.json. TextMouth packages import too.
- **Text pipeline:** every text format becomes Markdown at import, the book's content.md, with a marker line per chapter (`MarkdownCacheService.extractCache`). HTML goes through `HTMLToMarkdownConverter` (SwiftSoup), and text files through `TextFileDecoder`, which tries a byte-order mark, unmarked UTF-16, valid UTF-8, an HTML file's declared charset, and otherwise reads Windows-1252.
- **Export dialog** (FR05): it copies files and converts nothing. Its kinds are Audio, Original file, Text as Markdown, Text as plain text, Original recording, Original audio (before edits), and Transcript.
- **Audio editor's export** (FR04): M4A and M4B (AAC), Apple Lossless, WAV, AIFF, CAF, and MP3 through LAME 3.100, which is vendored in `Vendor/lame` and linked statically under the LGPL 2. Chapters are written in the MPEG-4 formats and in MP3 (ID3 CHAP and CTOC).
- **Installed ffmpeg:** `FFmpeg.swift` looks for one in Homebrew's and MacPorts' folders and on PATH, and uses it for filters, and for MP3 should LAME fail. TextMouth bundles nothing of ffmpeg.
- **Speech:** the engine renders speech to PCM buffers with `AVSpeechSynthesizer.write(_:toBufferCallback:)` (`AudioEngineService.swift`, lines 1170 to 1215).
- **Transcripts** (`Models/Transcript.swift`): per audio file, sentences with words, every time in whole milliseconds, made by SpeechAnalyzer on macOS 26.
- **Feeds:** OPML import and export already exist (FR03), flat and without duplicates. Podcasting 2.0 transcript and chapters links are stored on each item and never fetched.
- **Libraries:** ZIPFoundation (MIT; reads and writes ZIPs), SwiftSoup (MIT), swift-markdown (Apache 2.0), and LAME (LGPL 2). The app is not sandboxed (`TextMouth.entitlements`). It is about 11 MB, against an aim of 25 MB and a limit of 50 MB in `Scripts/check.sh`.

## 2. Text and word-processor formats

### 2.1 The shared route: textutil in a watched child process

- **What macOS gives (verified):** `NSAttributedString.DocumentType` reads plain text, RTF, RTFD, HTML, SimpleText, .doc (`docFormat`), WordML, Office Open XML, OpenDocument, and web archives. `textutil -convert` writes txt, html, rtf, rtfd, doc, docx, wordml, odt, and webarchive. Tried on files made here, it also reads .dot, .dotx, .docm, .dotm, and .ott by their content.
- **Threading:** Apple's documentation says HTML must not be imported from a background thread; it uses WebKit, and so do web archives (inferred). RTF, .doc, and ODT carry no such warning.
- **Cost in a child process** (verified with `/usr/bin/time -l`):
  - A 4 KB RTF converts to HTML in 0.04 to 0.10 s, peaking at 12 MB; a 20 KB .doc in 0.16 s and 15 MB.
  - A 3.3 MB RTF of 20,000 paragraphs takes 1.09 s and 59 MB; a 5.7 MB .doc converts to text in 0.47 s and 44 MB.
  - A hang or crash in Apple's readers then costs a child process, never the import, just as `afconvert` runs for Ogg. The runner under `WatchedProcess` is about 60 lines.
- **What survives** a round trip of an HTML file with h1, h2, a list, a table, and accents (verified, by tag counts):
  - Headings do not survive. From RTF, RTFD, .doc, .docx, WordML, and ODT alike, a heading comes back as a `<p>` in bold at 24 or 18 px, against a body of 12 px.
  - Lists survive from RTF and ODT as `<ul>`, but come back from .doc, .docx, and WordML as literal tab, bullet, tab.
  - Tables survive from RTF, .doc, and ODT; textutil's own DOCX writer wrote no table, a loss in the writer rather than the reader.
  - Accents and curly quotes survive everywhere. Only a web archive keeps h1, h2, lists, and tables, since it stores HTML.
- **Real heading styles are lost too:** an RTF written as Word writes it (a `\stylesheet` naming "heading 1" to "heading 3", `\s1` to `\s3`, and `\outlinelevel`) and an ODT with real `text:h` elements both come back with only size and bold (verified).

### 2.2 Finding headings

- **Route A, recommended now:** a pass before `HTMLToMarkdownConverter` takes the body's size as the commonest size by characters, makes a short bold or larger paragraph a heading, and gives it a level by size rank. It is about 100 lines; bold run-in headings and decorative text will fool it (inferred).
- **Route B, later if A fails:** a reader of the format's own styles (FMT47).
  - RTF, about 500 to 650 lines: groups, destinations, `\uN` and `\'hh` with code pages, `\stylesheet` names, `\outlinelevel`, tables, and lists.
  - .doc, about 450 to 600 lines, per Microsoft's [MS-DOC] specification (read by the worker): the compound file, the FIB (`wIdent` 0xA5EC, flags at 0x0A), the piece table, the style sheet (built-in styles 1 to 9 are Heading 1 to 9), and each paragraph's style from the PAPX pages. A 150-line Python prototype found Heading 1 to 6 in a real Word-format file from LibreOffice's tests (verified).
  - ODT, about 250 lines (FMT27).
- **Libraries are not needed:**
  - antiword, catdoc, and wvWare are GPL, so they cannot be linked into an MIT app.
  - libwpd is MPL 2.0 or LGPL 2.1 or later.
  - LibreOffice is MPL 2.0 and over 300 MB.

### 2.3 RTF and RTFD

- RTF is TextEdit's default format and a common export from Word; RTF 1.9.1 (2008) is its last specification. It is read by route A (FMT13), and by route B later.
- An RTFD is a folder holding TXT.rtf and its attachments, imported as one book, as a DAISY folder is. Attachments show as U+FFFC and are skipped.
- **Difficulty:** M with the runner, impact 5 (the user named RTF).

### 2.4 Word 97-2003 .doc and its template .dot

- A .doc is an OLE2 compound file holding the `WordDocument` and table streams. It is read by route A; a real Word-written .doc could not be tried through textutil, since downloads may not be opened by Apple's tools. Word 6 and 95 files and encrypted files are untested; an encrypted file should be refused with a sentence saying so.
- **A .dot is a .doc with the template bit set:** [MS-DOC] FibBase's `fDot`, the lowest bit of the flags word at byte 0x0A of the WordDocument stream (verified). With the bit set on a .doc made here, textutil read it the same with and without `-format doc`. The one real .dot found, in LibreOffice's tests, has the bit clear, so TextMouth should never test the bit: it accepts the extension and reads the content.
- **Difficulty:** .doc and .dot ride on FMT13 (M, impact 5, the user's wish); a reader of the real styles is FMT47 (L).

### 2.5 .dotx, .docm, and .dotm

- They are the same Office Open XML package as .docx; only the main part's content type differs (verified in real files).
- TextMouth's own Word reader opens fixed paths (word/document.xml, styles.xml, numbering.xml, the document's relationships, docProps/core.xml) and never reads the content type (verified), so all three open as they are, with real headings.
- Only XML parts are read, so a macro project (vbaProject.bin) is never touched and no macro runs.
- **Difficulty:** S, about 5 lines plus tests, impact 2 (FMT01).

### 2.6 ODT and OTT

- Both are ZIPs with the mimetype entry first and stored; an OTT differs only by its template mimetype. textutil reads both (verified), but its own ODT writer emits no `text:h`, so tests of headings use the hand-written sample.
- A small reader of content.xml and meta.xml gives exact headings, lists, tables, title, and author, in about 250 lines (FMT27, M, impact 2).

### 2.7 WordML and web archives

- **WordML** is Word 2003's single XML file, rare since 2006, and textutil reads it; it rides on FMT13, impact 1.
- **A web archive** is a binary property list whose `WebMainResource` holds the page's HTML, its MIME type, and its text encoding (verified). Reading it with `PropertyListSerialization` and handing the HTML to the existing converter needs no WebKit and loads nothing from the network: about 40 lines (FMT03, S, impact 2). A web archive written by Safari was not tried.

### 2.8 FictionBook, MOBI and AZW3, and DTBook and NIMAS

- **FB2** is XML: a title-info description, nested sections whose titles give the heading levels, epigraphs, poems, notes, and base64 images. It is common among Russian-language public-domain books, often in windows-1251. An XMLParser reader is about 250 lines, with .fb2.zip through ZIPFoundation (FMT26, M, impact 2).
- **MOBI**, verified on the MobileRead wiki and on a real file:
  - The file is a PalmDB of records. Record 0 holds the PalmDOC header, with compression at offset 0 and encryption at offset 12, then the MOBI header, with the code page, the EXTH flag, and the DRM fields at offsets 168 to 180 (0xFFFFFFFF for none). Refuse any file with DRM.
  - Project Gutenberg's .mobi is MOBI 6, not KF8. A 25-line PalmDOC decompressor reproduced its 68,150 bytes exactly: old HTML with `filepos` anchors and `mbp:pagebreak`, and no h1 to h3, with chapters in the NCX index records. So "KF8 is basically HTML inside a PalmDB container" holds only in part.
  - A MOBI 6 reader is about 500 lines (FMT42, M, impact 2). KF8 (AZW3) adds skeleton, fragment, and flow tables, about 700 lines more (FMT48, L).
  - libmobi (LGPL 3), KindleUnpack, and calibre (both GPL 3) are references to study only; a clean reader written from the wiki is the route.
- **DTBook and NIMAS** (verified in `DAISYParser.swift`):
  - The DAISY reader already reads DTBook in a DAISY 3 package, and finds a DTBook in a ZIP or folder without an OPF, so a NIMAS package should import today (inferred; untested).
  - What fails is a single loose .xml file, which `BookFormat` does not list. Sniffing the root element and a one-file provider take about 55 lines (FMT04, S, impact 2).
  - NIMAS files reach students only through their schools or Bookshare, under IDEA, never as public files.
- **CHM** (ITSF container, LZX compression, an .hhc contents file) would need a port of about 700 lines; chmlib is LGPL 2.1. It is set aside, impact 1 to 2.

### 2.9 Plain text in other encodings

- `TextFileDecoder` reads every text that is not UTF-8 or UTF-16 as Windows-1252, so Mac Roman, Central European, Cyrillic (Windows-1251, KOI8-R), and Japanese or Chinese files arrive garbled. The listener gets no warning: the fallback is only logged (verified, lines 86 to 114).
- Foundation's `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)`, called from JavaScript for Automation on 13 short files made here, named the right encoding for 11 of them. It was wrong for Mac Roman (it guessed 1251) and KOI8-R (ISO 8859-5), and it always answers, never saying it is unsure (verified).
- **Recommended:** use it as a guess after today's checks, name the encoding in Book Info, and add a Reopen with Encoding command. A letter-frequency check can catch Mac Roman and KOI8-R (FMT16, M, impact 4: silent garbling is the worst failure for a listener).

### 2.10 Pages, WordPerfect, and others: refuse with advice

- **Pages 5 and later** is a ZIP of `Index/*.iwa` files (Snappy-framed protobuf, undocumented) with a preview.jpg and no PDF (verified on a real file). Pages 4 holds index.xml and a one-page preview PDF. A reader of the IWA files is XL and brittle across versions; refuse and say "export it from Pages as Word or EPUB" (FMT02).
- **WordPerfect** has no macOS reader, and libwpd is over 1 MB of C++; refuse it. Microsoft Reader .lit (dead since 2012, with DRM), Works .wps, and AbiWord are set aside.

## 3. Braille

### 3.1 The formats

- **BRF (Braille Ready Format)** is plain ASCII text of finished braille pages: 63 dot patterns and the space as the characters 0x20 to 0x5F, with CR, LF, and form feeds. It has no official standard (Library of Congress, format description 551). It is produced by NLS BARD, Bookshare, Duxbury, BrailleBlaster, and liblouis. Bookshare offers 18 to 80 cells a line for displays and 28 to 40 by 25 lines for embossers (verified), so a reader must accept widths from 18 to 80.
- **BRL** is the same 64-character braille ASCII, unformatted. Orbit Reader 20's guide calls BRF and BRA "translated, formatted braille" and BRL "translated, unformatted braille" (verified). APH's Mantis Q40 and HumanWare's Brailliant open both. Duxbury writes no .brl. No real .brl file was found to check.
- **PEF (Portable Embosser Format)** is XML by the Swedish agency TPB with the DAISY Consortium, from 2008: the namespace `http://www.daisy.org/ns/2008/pef`, then volumes, sections, pages, and rows of Unicode braille only (U+2800 to U+28FF). Its metadata requires an identifier and a format (verified from its schema). It is used in Scandinavia and rare in the US; it suits embossers more than displays.
- **eBraille** is the DAISY Consortium's standard, proposed by APH with the NFB. Version 1.0 was published on August 14, 2025 and approved in November 2025 (verified). It is an EPUB-like ZIP (`.ebrl`) of XHTML whose text is Unicode braille, with headings, lists, and tables as HTML, reflowable to any line length. HumanWare's displays began reading it in January 2026; BARD still serves BRF (FMT40, M, impact 2 and rising).

### 3.2 Reading: cells, pages, and headings

- **The table**, verified 64 of 64 against liblouis's `en-us-brf.dis`: the string ` A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)=`, indexed by the cell's dot value 0 to 63 (dot 1 counts 1, dot 6 counts 32). The Unicode cell is U+2800 plus the index; a lowercase letter is read as its capital.
- **Pages and headings,** by BANA's Braille Formats: Principles of Print-to-Braille Transcription (2016), verified:
  - A page is 40 cells by 25 lines. Paragraphs start in cell 3, with runovers in cell 1, and no word is divided at a line's end.
  - The print page number goes at the end of line 1. The braille page number goes at the right margin of the last line, with at least three blank cells before it.
  - A centered heading has a blank line before and after it, with at least three blank cells on each side; there are cell-5 and cell-7 headings too.
- **How TextMouth would read one:** split pages at form feeds (else every 25 lines), take the braille page number from the last line, and find headings from centered lines with blank lines around them and from cell-5 and cell-7 lines. This is a heuristic, since producers vary.
- **Uncontracted braille** (UEB Grade 1) translates back to print almost deterministically. The worker's decoder round-trips the 12-paragraph sample and seven hand-worked UEB cases (capitals by word and passage, 2024, 5a, 3.14, don't, (a)) in about 110 lines (FMT20, M with the page model, impact 3).

### 3.3 Contracted braille: liblouis and macOS 26

- **Why it is hard:** contractions follow context rules, and one cell has many readings. ⠉ is the letter c or the word "can"; the letters a to j are digits after ⠼; ⠦ opens a quotation while ⠰⠦ is a question mark. EBAE, the US code before 2016, differs from UEB.
- **liblouis** (verified in its repository):
  - The library is LGPL 2.1 or later, and so is the UEB Grade 2 table's header; its command-line tools are GPL 3. `lou_backTranslateString` is the inverse of `lou_translateString`.
  - No accuracy figure for back-translation was found. Its backward tests are small (8.8 KB, against a 4.2 MB forward harness), and BANA's spring 2026 summary says typeforms do not back-translate. "Good enough to listen to" is plausible, not proven.
- **Size:**
  - The core C sources are 504 KB. Apple's compiled universal copy is 406,608 bytes, so about 0.2 to 0.3 MB per architecture (inferred).
  - UEB Grade 2 needs 9 table files, 238,925 bytes on master (Grade 1 alone, 89,297 bytes). All 481 tables come to 13.9 MB, so bundle only the few needed. The total is about 0.5 to 0.7 MB.
- **Linking:** the LGPL allows a non-GPL app to link liblouis if the user can relink it. TextMouth's LAME precedent fits: the unmodified release in `Vendor/`, built statically through project.yml from source in the repository, with its licence text and a notice in `docs/developer/third-party-code.md`. A hand-written config.h would replace the autotools one. Tables load from files at run time (`lou_setDataPath`), so they ship as resources. liblouis is treated as not thread-safe (secondary sources and an open upstream issue), so every call goes through one serial queue.
- **macOS 26** (the lead verified each point):
  - `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable` holds liblouis 3.34.0 for VoiceOver, and `/Library/Documentation/Acknowledgements.rtf` names it. It is a private bundle that an app cannot load. A Duxbury table bundle sits beside it.
  - The SDK's `Accessibility.framework` has a public `AXBrailleTable` and `AXBrailleTranslator` (`translatePrintText:`, `backTranslateBraille:`, Unicode braille in and out, a location map), available from macOS 26.0. Its tables come from `supportedLocales`, `defaultTableForLocale:`, `tablesForLocale:`, and `initWithIdentifier:`.
  - From a command-line program on this Mac (26.3.1), every one of those calls returned nothing: no locales, no tables, and nil for each identifier tried (the lead reran the worker's probe). Whether an app bundle gets tables is unknown.
  - `BrailleSymbology.framework` holds no tables. No public API before macOS 26 translates braille.
- **Recommendation:** vendor liblouis (FMT21, M, impact 5). Before that, spend a day on a spike of `AXBrailleTranslator` inside an app bundle: if it serves the UEB tables there, use it on macOS 26, and liblouis on 14 and 15. Writing our own Grade 2 translator is XL (FMT51): liblouis's UEB Grade 2 table alone is about 150 KB of rules (2,037 rule lines in Apple's copy).

### 3.4 Writing: the encoder and the layout

- **Grade 1 UEB must handle** (ICEB's Rules of Unified English Braille, 2013; checked cell by cell against liblouis's character definitions):
  - letters, and capitals by letter, word, and passage (⠠, ⠠⠠, and ⠠⠠⠠ closed by ⠠⠄);
  - the numeric indicator ⠼, with a decimal point and comma staying numeric, and the grade 1 indicator ⠰ before a to j after a digit;
  - punctuation: ? as ⠰⠦, quotation marks ⠦ and ⠴, the apostrophe ⠄, the dash ⠠⠤, brackets ⠐⠣ and ⠐⠜;
  - and the italic word indicator ⠨⠂.
  - Not handled: mathematics, accented letters (the dots-4-5 prefixes), other languages, tables, code, poetry, and boxed text.
- **The layout:** 40 by 25 cells, centered headings, paragraphs in cells 3 and 1, the braille page number on the last line, no divided words, and a form feed between pages. The worker's prototype does all this for plain paragraphs, with a PEF writer, a reader, and the Grade 1 decoder, in 428 lines of Python; in Swift that is about 500 to 600 lines with tests. With liblouis translating, the layout alone is about 250.
- **Settings readers expect** (Bookshare's options): cells per line (18 to 80 for displays, 28 to 40 for embossers, 40 by default), lines per page (25), grade 1 or 2, braille and print page numbers, volume splitting for embossing, and CR LF line ends (FMT22, M, impact 4).

### 3.5 What a braille reader would expect, and what macOS already does

- **What TextMouth adds:** hearing a BRF as print, putting it in the library with a reading position and bookmarks, navigating by braille page, print page, and heading, searching, and exporting any book to BRF.
- **Braille Access** in macOS 26 opens BRF files on a braille display, with search and bookmarks, but no speech, back-translation, or page navigation, by Apple's support page (verified).
- **Exact cells while speaking has no supported route.** No macOS API sets an element's braille string (verified in the SDK headers). VoiceOver translates whatever text TextMouth shows into the user's own braille table, and its handling of literal Unicode braille on macOS is untested (on iOS a developer reports bracket cells around it). Showing the cells would also make VoiceOver speak them. The recommendation is to show the back-translated print and to say, in Book Info, that Braille Access shows the cells (question 6).

## 4. Audio

### 4.1 The standard target

- **Lossy sources** (WMA, Speex, AC-3, AMR, MP2, and Opus or Vorbis in Matroska) become AAC-LC in .m4a, as Ogg does now, at the source's own bit rate rounded up to a standard AAC rate. The rate must follow the sample rate, as the Ogg converter's accepted rates do: `afconvert` refused 48 kbit/s for an 8 kHz Speex file (verified).
- **Lossless sources** (FLAC in Ogg, APE, WavPack, TTA, WMA Lossless, PCM in CAF) become Apple Lossless in .m4a. That is the same container, tags, and chapters as the AAC path, and the audio editor already exports it. FLAC itself plays, but its chapters need Vorbis comments or a cue sheet, while TextMouth's book model reads MPEG-4 chapters.
- **DSD** decimates to PCM. One hour of DSD64 stereo is about 2.5 GB, so even Apple Lossless is large for it, and AAC may be the better target.
- **Ogg FLAC:** `afconvert` turns an Ogg FLAC file into Apple Lossless (verified on a file made here), so the refusal of Ogg FLAC can be lifted (FMT14).

### 4.2 What macOS already reads

- **`afconvert -hf` lists what it writes** (verified): 3GPP and 3GPP2 (AAC and AMR), ADTS, AC-3, E-AC-3, AIFC, AIFF, AMR, M4A and M4B, CAF (with Opus, ALAC, FLAC, IMA4, MS ADPCM, and Vorbis among its data formats), FLAC, MPEG layers 1 to 3, MP4, NeXT/Sun .au and .snd, Ogg (Opus, FLAC, Vorbis), WAVE (PCM, μ-law, A-law, MS and IMA ADPCM), RF64, BW64, and Wave64.
- **Read and playable** (verified: `afinfo`, `afconvert` to AAC, and AVFoundation's `isPlayable`, on files made here): AC-3, E-AC-3, AMR-NB (.amr, and in .3gp), MP2, .au, AIFC (IMA4, μ-law), CAF (PCM, ALAC, Opus), Wave64, RF64, 24-bit WAVE_FORMAT_EXTENSIBLE, MS ADPCM and A-law WAV, BWF (its two cue markers read as markers; its `bext` chunk ignored), 3GP with AAC, MPEG-TS with AAC, and AVI with PCM.
- Apple's archived Core Audio Overview, written for OS X 10.5, says AC-3 cannot be decoded; that is out of date (verified).
- **Refused by Core Audio and AVFoundation** (verified): WMA, WavPack, TTA, Speex, all Matroska and WebM, FLV, AVI with MP3, and MIDI as audio.
- **TextMouth already accepts** `.wav` in all its variants. The free extensions to add are aifc, caf, au, snd, w64, ac3, ec3, eac3, mp1, mp2, mpa, amr, awb (AMR-WB, untested), 3gp, 3g2, and 3ga.
- **Recommended route:** the coded ones (AC-3, E-AC-3, AMR, MP1 and MP2, CAF and AIFC with Opus, IMA4, or ADPCM, and 3GP) convert at import through the same watched `afconvert` as Ogg, so Apple's rarer decoders stay out of the player, as October 14 taught. Plain PCM containers play as they are. Generalize `OggAudioConverter` into one import converter with a plan per file (FMT09, S, impact 3, the user's wish).

### 4.3 What needs ffmpeg: installed or bundled

- **(a) The user's installed ffmpeg, recommended first.**
  - `FFmpeg.locate` already finds it. Homebrew's 7.1.1 on this Mac is built with `--enable-gpl --enable-version3`, which is fine because TextMouth distributes nothing of it.
  - It has `aac_at`, Apple's AAC encoder inside ffmpeg (verified in `-encoders`), so one pass converts with no temporary PCM: `ffmpeg -nostdin -hide_banner -protocol_whitelist file -f <forced demuxer> -i IN -map 0:a:N -map_chapters 0 -map_metadata 0 -c:a aac_at -b:a RATE OUT.m4a`.
  - AVFoundation read both chapters back from an .m4a made this way from a two-chapter .mka (verified). FFmpeg's AAC guide ranks `aac_at` at or above libfdk_aac, above its native `aac` encoder.
  - Safety: run it under `WatchedProcess` with the Ogg converter's limits, force the demuxer from TextMouth's own sniff of the first bytes so ffmpeg never probes exotic formats, and whitelist only the file protocol. ffmpeg's own Vorbis and Opus decoders also keep Apple's Vorbis decoder out of the loop (inferred).
  - Without ffmpeg, the alert says what to install (question 9).
- **(b) A bundled ffmpeg** (FMT50, L, impact 2):
  - The build: `--disable-everything --disable-autodetect --disable-network --enable-audiotoolbox`, with the file protocol and only the needed demuxers, decoders, parsers, and the ALAC, PCM, MP4, and WAV writers.
  - Its size is not measured. Reports give 1 to 2 MB for builds of what one needs, and Homebrew's full libraries here total 13.3 MB for one architecture; the estimate is 1.5 to 3 MB universal (inferred).
  - Obligations (ffmpeg.org's legal page, verified): stay LGPL by enabling no GPL or non-free parts; publish the exact source, its changes, and the configure line; name ffmpeg in the About window; add no clause against reverse engineering. A separate executable meets the linking terms simply (inferred), but needs a rebuild on every ffmpeg security release.
- **(c) Small single-format decoders** run as helper executables: libwavpack (BSD 3-clause, fuzzed), the Monkey's Audio SDK (its own BSD-style licence), libmpcdec (BSD, unmaintained), libopenmpt (BSD 3-clause, patched often), and FluidSynth (LGPL 2.1, needs a SoundFont). Each adds a licence, a build, and updates, so this only pays for tracker modules, which Homebrew's ffmpeg cannot decode.
- **Through (a):** WMA v1 and v2, WMA Pro, Lossless, and Voice (ffmpeg has all five decoders), WavPack, TTA, APE, Speex (obsolete, "replaced by Opus" per speex.org), Musepack, RealAudio, and the sound of AVI, FLV, and MPEG-TS (FMT31, M, impact 3, the user's wish).

### 4.4 Matroska and WebM, and choosing a track

- These are containers, not codecs: they hold Opus, Vorbis, AAC, FLAC, AC-3, or PCM, often several tracks. ffprobe's JSON names each track's language and title (verified on the two-track sample).
- **The rule:** take the track marked default, else the first in the system's language, else the first. When several exist, a sheet names them ("Narration, English"), so a book never plays two hours of commentary by mistake (ChatGPT's point, sound).
- An AAC track can be copied into .m4a without re-encoding (`-c:a copy`), avoiding a second lossy pass (inferred).
- Matroska chapters become headings (verified through ffmpeg). Refuse linked segments, which point to other files (FMT32, M, impact 3).

### 4.5 MIDI, tracker modules, and DSD

- **MIDI:** `AVMIDIPlayer` takes "a SoundFont2 or DLS bank", nil meaning the default on macOS (header, verified), and macOS ships `gs_instruments.dls` (1,996,068 bytes) in `/System/Library/Components/CoreAudio.component/Contents/Resources/`. AVMIDIPlayer only plays, though; an offline render to PCM uses `AVAudioSequencer` with `AVAudioUnitSampler` in a manual-rendering `AVAudioEngine` (in the headers; not run). Its General MIDI sound is plain. Marker events become chapters (FMT41, M, impact 1).
- **Tracker modules** need libopenmpt in a helper (L, impact 1, set aside).
- **DSD** goes through ffmpeg (`dsf` demuxer and `dsd_*` decoders, verified): its files are huge and rare, so it follows FMT31 later.

### 4.6 Patents and licences in 2026

All marked inferred unless said.

- MP3 and MP2 patents have expired. AC-3's last expired on March 20, 2017. E-AC-3's last, US 7,516,064, expired on January 30, 2026.
- AAC is still licensed by Via's pool (Fraunhofer's page, verified), with expiries reported from 2028 to 2031; TextMouth uses Apple's encoders, as with Ogg today.
- AMR: most of VoiceAge's families expired by 2019, others in 2022 or 2024.
- Opus, Vorbis, FLAC, Speex, WavPack, TTA, Monkey's Audio, and Musepack are royalty-free as far as known. WMA's patent status was not verified; ffmpeg decodes it without a licence.

### 4.7 Keeping the original, and the words "sounds no worse"

- Today an Ogg import deletes the staged Ogg and keeps only the .m4a (`FileImportService+Ogg.swift`, `removeSources`, verified).
- ChatGPT's correction is right. A second lossy encoding cannot promise "sounds no worse": FFmpeg's guide says lossy to lossy "can reduce quality even at the same or a higher bitrate". The rounded-up bit rate does not keep the size the same either.
- `docs/user/what-textmouth-reads.md` should say plainly what conversion does.
- **Recommended:** convert lossless to lossless, and keep the original beside the converted file, behind a setting (question 10). The disk cost is about the size of the source.

## 5. Playlists, cue sheets, transcripts, and chapters

### 5.1 Embedded chapters TextMouth reads today

- `AudioPlaybackService.extractChapters` asks AVFoundation for chapter groups in the file's own chapter languages, falling back to "en"; a file in the "und" language is therefore read (verified in the code).
- A throwaway probe with the same calls, on files made here (verified):
  - The QuickTime chapter track (M4B, M4A, MOV, MP4), MP3's ID3 CHAP frames, and FLAC's `CHAPTER001=` and `CHAPTER001NAME=` comments are read.
  - **A Nero `chpl` atom alone is not read:** a file whose chapter-track reference was renamed showed none. Some audiobook tools write only `chpl` (inferred), so such books show no headings. A reader of the atom by hand is about 80 lines (FMT05, S, impact 3).
  - **The FLAC CUESHEET block is not read** by AVFoundation (ffmpeg shows it): it goes with FMT24.
  - Ogg's `CHAPTERnn` comments never reach AVFoundation, by design. `OggHeaderReader` could read them and the converter could carry them into the .m4a (FMT17).
- ChatGPT's "plays M4B" versus "preserves its chapter navigation" is a fair distinction: the documentation does not say which chapter kinds are read.

### 5.2 Playlists: M3U, M3U8, PLS, and XSPF

- **M3U and M3U8:**
  - The format is one path or URL per line, with an optional `#EXTM3U` and `#EXTINF:seconds,title`.
  - HLS streaming playlists (RFC 8216, verified) share the extension and the first line, and carry `#EXT-X-` tags. Refuse them in a sentence, and never fetch a URL.
  - A legacy .m3u is Windows-1252 or Latin-1, with Windows backslashes (inferred); `TextFileDecoder` fits it exactly.
  - The import writes the manifest in memory: one heading per entry, titled by `#EXTINF` or else the file name, in the playlist's order (FMT10, S, impact 3).
  - The app is not sandboxed, so a playlist can name any file the user can read. The recommended policy is files inside the playlist's folder only, with the entries skipped named (question 11).
  - ChatGPT's "remove the ZIP step" is done already: Import Folder… has imported a plain folder of tracks since October 14.
- **PLS** is an INI file (`FileN`, `TitleN`, `LengthN`), mostly internet-radio links TextMouth cannot play. **XSPF** is XML (`trackList`, `location` URIs resolved against `xml:base`), used by VLC (FMT12, S, impact 1).

### 5.3 CUE sheets

- A cue sheet lists `FILE "x.wav" WAVE`, then `TRACK 01 AUDIO` entries with `TITLE`, `PERFORMER`, and `INDEX 01 MM:SS:FF` in frames of 1/75 second; `INDEX 00` marks a pregap, and `REM` lines are comments.
- The GNU and Hydrogenaudio pages could not be loaded (HTTP 429 and 403), so this syntax is from experience. `metaflac` confirmed the 75-frame rule: it refused an 8 kHz sheet, "MM:SS:FF form not allowed if sample rate is not a multiple of 75".
- **The import:**
  - A heading per track, starting at INDEX 01.
  - Several FILEs map onto the manifest's segments, where a heading is a stretch of the audio files (verified that the segment model exists).
  - The sheet is decoded by `TextFileDecoder`.
  - A FILE whose name does not match falls back to the file with the same stem beside the sheet, since sheets often name a .wav later compressed to .flac.
- **Also:** the FLAC CUESHEET block, an APE or WavPack `Cuesheet` tag (with FMT31), and CUE export of a book's chapters (FMT24, M, impact 4).

### 5.4 Timed text: SRT, WebVTT, LRC, and TTML

- **SRT** has no standard: numbered cues, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, text, and a blank line, with `<i>` and `<b>` tags and encodings that vary.
- **WebVTT** (W3C, verified) is UTF-8: a `WEBVTT` header, optional cue identifiers, `MM:SS.mmm` times with optional hours, NOTE blocks, and `<v Name>` voice tags. Podcasting 2.0 recommends it first (verified).
- **The import:** each cue becomes a `TranscriptSentence` (text, start, end, no word times), and voice tags become "Name: " text. The file is attached to an audiobook by name (lecture.vtt beside lecture.m4a, or a cue file per track in a ZIP or folder) or by a Book menu command. The fingerprint and length are recorded as the recognizer records them.
- **The export** writes either format from transcript.json, one file per track or one for the book.
- **Cost:** one cue model with two readers and two writers, about 250 lines (FMT23, M, impact 4). It needs no SpeechAnalyzer; whether a saved transcript shows on macOS 14 and 15 was not checked.
- **LRC** (lyrics; `[mm:ss.xx]` lines, enhanced word times) and **TTML or IMSC** (W3C XML with clock, offset, frame, and tick times, and agents for speakers) are more readers for the same model (FMT37, M, impact 2).

### 5.5 Podcasting 2.0 transcripts and chapters

- **The tags** (podcasting2.org, verified):
  - `podcast:transcript` gives a URL, a type (text/plain, text/html, text/vtt, application/json, application/x-subrip), and optionally a language and `rel="captions"`.
  - The JSON transcript is version 1.0.0, with segments of speaker, startTime, endTime, and body in seconds.
  - The chapters JSON is version 1.2.0: chapters with a startTime and optional endTime, title, img, url, toc (false hides it), and location.
- **What it would add:** fetch both beside the episode's download, under the download's network rules, preferring WebVTT, then JSON, then SRT (text and HTML have no times). The episode then has a synchronized transcript at once, on any macOS, with no recognition, and headings when it has none of its own.
- Claude's "probably the highest-value item on the list" is half true: TextMouth stores the links and fetches nothing (verified), and it is the best of this family because the feed already carries the audio, but it depends on publishers.
- **Risks:** the app's first fetch of third-party text (cap its size, treat it as data, follow none of its links), and a transcript of another edition, since dynamic ads shift times (compare durations). FMT25, M, impact 5.

### 5.6 Audacity labels, EDL, and oTranscribe

- **Audacity's label file** (its manual, verified) is UTF-8 text: start, end, and label, tab-separated, in seconds. A point has equal times; a line starting with a backslash holds a spectral selection. Import as bookmarks or headings, and export headings, bookmarks, or the editor's markers, for a round trip with an audio editor (FMT06, S, impact 2).
- Gemini's Audacity `.aup3` project is a SQLite database tied to Audacity's schema: not worth adopting.
- **EDL (CMX 3600)** is a video cut list, without a frame rate in the file and with markers only as vendor comments; Gemini's "essential for DAWs" is loose. **oTranscribe's .otr** is JSON of HTML text plus a media time, from a browser tool; "the de facto standard" is overstated. Both are set aside.

### 5.7 OPML

- Import and export work today: every outline with an `xmlUrl` at any depth, each address once, tolerant of bad markup, with a 10 MB cap; export is flat OPML 2.0 (verified in `FeedOPML.swift`).
- What is missing is folders: Overcast, Pocket Casts, and Apple write feed outlines inside folder outlines, and TextMouth drops them and writes none. Keeping them needs a group on each feed (FMT38, M, impact 2).

### 5.8 EPUB 3 Media Overlays

- **The format** (EPUB 3.3, section 9, read in part): a chapter's manifest item names an `application/smil+xml` overlay. The overlay's `par` elements each hold one `text` fragment and at most one `audio` clip with `clipBegin` and `clipEnd`, and the package gives `media:duration` for the book and each overlay.
- Claude's "conceptually DAISY again" is mostly true: `DAISYAudioSMILParser` already reads `par`, `text`, and `audio` with clip times.
- **A gap in today's code:** its `parseTime` reads a SMIL timecount with `h`, `min`, or `ms` as 0 ("500ms" loses its "s", fails as "500m", and returns 0; "2min" returns 0). The lead verified this in `DAISYParser+Audio.swift`, line 129. It is a fix this item needs, and DAISY 3 books may already need it.
- **Best fit:** import such an EPUB as an audiobook in SMIL order, with headings from nav.xhtml and a transcript built from the pars, so it follows the narration as a transcribed audiobook does, on any macOS (FMT46, L, impact 3).
- **Risks:** `src` paths that climb out of the package, and Ogg audio inside, which goes through the converter.

### 5.9 Voice notes, OverDrive, and CD images

- **WhatsApp and Telegram voice notes** are Opus in Ogg (from secondary sources), which TextMouth already imports by converting it; Signal's format was not verified. A chat export's voice notes therefore already import as a book of tracks; only date order by their names is missing.
- **OverDrive .odm** is an XML pointer to a licensed download through a retired client, with DRM: not to be done.
- **Audio CD images** (.bin with .cue, or .toc) could be wrapped as WAV with the cue code; impact 1, set aside.

## 6. Slides, spreadsheets, images, email, and speech markup

### 6.1 PowerPoint, Keynote, and ODP

- **PowerPoint (.pptx and .ppsx)** is PresentationML in a ZIP (verified in the sample):
  - Slide order comes from presentation.xml's `sldIdLst` through its relationships, not from file names. Notes are in notesSlides, linked from each slide.
  - Each slide's title becomes a heading (else "Slide N"), its text follows in order, tables are read a row at a time, and pictures' alt text is read. Notes are optional, and hidden slides are skipped.
  - About 350 lines (FMT33, M, impact 3).
- **Keynote and Numbers** are undocumented IWA protobuf whose schemas are dumped from the running apps and change between releases (keynote-parser's README, verified). libetonyek covers only old versions and needs Boost. Refuse them, and say to export to PowerPoint, Excel, or PDF (FMT02).
- **ODP** has a `draw:page` per slide with its title frame and notes (FMT36).

### 6.2 CSV, TSV, XLSX, ODS, and XLS

- **CSV:** RFC 4180 is only informational (verified). Real files use semicolons, tabs, and pipes, and have byte-order marks and old encodings.
- **How a row reads:** today's HTML tables join a row's cells with a space only ("Pens 12 true"), which reads badly. Recommended: one paragraph per row, cells joined by ", ", the header row first, with an optional setting to say each column's name (question 15), and a row cap with a notice for huge files. About 250 lines (FMT15, M, impact 3). Claude's "CSV is nearly free" is half true.
- **XLSX:** sheet order and names come from workbook.xml, strings from sharedStrings.xml, and formulas carry cached values. Dates are numbers that need the number formats and the 1900 or 1904 epoch, or a listener hears "45123". About 450 lines (FMT35, M, impact 2).
- **ODS** stores repeated rows and columns as counts, and a blank trailing run can claim a million rows, so cap the expansion (FMT36).
- **Legacy .xls** (BIFF8 in a compound file) is about 900 lines and is set aside. Its compound-file reader would be shared with the .doc reader (FMT47).

### 6.3 Pictures of pages and comic archives

- ImageIO reads PNG, JPEG, HEIC, HEIF, TIFF, AVIF, GIF, BMP, and JPEG 2000 on this Mac, but not WebP (verified).
- Vision's text recognition, with 30 languages here, read every line of the PNG, JPEG, and HEIC samples and both pages of the two-page TIFF (verified).
- **A finding:** a PNG of black text on a transparent background gave nothing. Flatten every image onto white first, apply its EXIF orientation, which `VNImageRequestHandler(cgImage:)` ignores, and cap the pixel size before decoding: a 300 dpi A4 page in RGBA is about 35 MB.
- **CBZ** is a ZIP of page images in natural name order, often with a ComicInfo.xml; Vision gives no panel order.
- **CBR is RAR:** libarchive reads RAR "with some limitations", but the SDK has no public `archive.h`, and unrar's licence is unfree. Accept a CBR that is really a ZIP, and refuse a real RAR (FMT34, M, impact 4, for photographed letters, menus, and mail).

### 6.4 Email

- Foundation has no MIME parser, so TextMouth would write one. It needs:
  - header folding and RFC 2047 encoded words;
  - quoted-printable and base64, and charsets;
  - multipart/alternative (prefer the plain part, else the HTML part through the existing converter) and format=flowed;
  - attachments listed by name, nested messages, and no remote images.
- **mbox:** RFC 4155 prescribes no escaping of "From " lines (verified), so a reader handles both mboxrd and mboxo, finds the separator by its pattern, and streams line by line.
- Each message becomes a heading ("Subject, from, date"). About 850 lines (FMT45, L, impact 3).

### 6.5 SSML and pronunciation lexicons

- **SSML playback:** `AVSpeechUtterance(ssmlRepresentation:)` exists from macOS 13 and returns nil for invalid SSML, and the rate, pitch, and volume properties do not apply to it (header, verified). Measured on macOS 26.3.1, rendering to buffers, nothing played:
  - `break` and `prosody` are honored, and `say-as` changes the output.
  - `sub` aliases are ignored.
  - **Every `emphasis` element crashed the probe** (SIGSEGV, exit 139). The live `speak` path is untested.
- **SSML import:** TextMouth's October 7 finding (`SpeechMarkupGuard`) is that the engine treats tag-shaped text in a plain string as markup and refuses or truncates it. So an SSML file imports as text with its markup removed, never as SSML and never as raw tags (FMT07, S, impact 2). Claude's "control pauses and pronunciation precisely" overstates it.
- **W3C PLS lexicons** (PLS 1.0, 2008): no Apple API takes a lexicon file (verified). IPA works per word as an attributed-string attribute, `AVSpeechSynthesisIPANotationAttribute`, available from macOS 10.14, and changed the output on macOS 26.3.1 (verified). A lexicon's aliases map onto TextMouth's substitution rules, in and out; its phonemes have no text form and are set aside (FMT08, S, impact 2).
- EPUB 3.3 shows PLS only in a non-normative example.

### 6.6 DjVu and XPS

- **DjVu:** DjVuLibre is GPL, and an own reader is XL. Refuse it and point to conversion.
- **XPS and OXPS** (ECMA-388) hold text in `Glyphs` elements in paint order, without headings: M, impact 1, set aside.

## 7. Export

### 7.1 Today

- The Export dialog copies a book's files by kind (section 1). The audio editor's Export writes seven formats with chapters in the MPEG-4 ones and MP3; its dialog says WAV, AIFF, and CAF leave chapters out. MP3 tags carry title, author, and the gapless numbers.

### 7.2 The Convert to choice

- **Each kind the dialog lists gains a Convert to choice:**
  - Text: HTML, RTF, EPUB 3, DOCX, ODT, BRF, and PEF.
  - Audio: the editor's formats, and FLAC later.
- **The job runner** gives the dialog's existing progress bar, Stop, and VoiceOver sentences, with names that never replace a file.
- **Its first writer is HTML,** from content.md through TextMouth's own swift-markdown walker: escaped XHTML with h1 to h6 and ids, the language, a title, and a contents list. swift-markdown 0.9.0 does have an `HTMLFormatter`, but it inserts text unescaped, so an "&" or "<" in a book breaks the page, and it drops heading ids (verified in its source).
- The same walker feeds every other text writer (FMT18, M, impact 4, the user's wish).

### 7.3 Text to text

- **Apple's writers drop headings** (verified): `textutil` and `NSAttributedString`, even given paragraph styles with header levels 1 and 2, wrote DOCX with no Heading1 style or outline level, ODT with no `text:h`, and RTF with no `\outlinelevel`. Only the HTML writer keeps h1 and h2. A Word navigation pane, VoiceOver's heading navigation, and LibreOffice's Navigator would find nothing.
- **DOCX and ODT written by TextMouth:**
  - DOCX: styles.xml with Heading1 to 6 (`w:outlineLvl`), and core properties.
  - ODT: the mimetype stored first, and `text:h` with outline levels.
  - The worker's prototypes read back with their headings in pandoc and textutil. Neither was opened in Word or LibreOffice (FMT29, M, impact 3).
- **EPUB 3 written by TextMouth,** with ZIPFoundation, whose writer adds entries in call order and stores with `.none` (verified at 0.9.20): the mimetype first and stored, container.xml, the package document with accessibility metadata, nav.xhtml from the headings, and an XHTML file per chapter. A prototype passed EPUBCheck (EPUB 3.3 rules) with no errors or warnings (verified). FMT28, M, impact 4.
- **RTF written by TextMouth:** a font table, heading styles with `\outlinelevel`, and Unicode as `\uN`, about 120 lines; its outline levels in Word are inferred, not tried. A .doc can be offered only through Apple's writer, with plain headings; writing Word's binary format ourselves is unwise (FMT19, S, impact 3, the user's wish).
- **Tagged PDF:** AppKit's PDF has no structure tree, but Core Graphics' `CGPDFContextBeginTag` writes one (verified: H1 and P tags, `/MarkInfo` marked). Pages laid out with Core Text, with an outline from PDFKit, are about 400 lines (FMT49, L, impact 2: for sighted sharing and printing).

### 7.4 Text to braille

- The encoder of section 3.4 gives cells per paragraph. The export lays out pages, writes BRF in braille ASCII with CR LF and form feeds, or PEF as XML, and offers the settings of section 3.4 (FMT22).

### 7.5 Text to audio by speech

- **The pipeline:**
  - For each chapter in the chosen range, take the same reading text the reader speaks: substitution rules, pauses, and `SpeechMarkupGuard`.
  - Render it in the reader's chunk size with a fresh `AVSpeechSynthesizer`'s `write(_:toBufferCallback:)`, as `AudioEngineService` does, appending buffers to a 16-bit PCM CAF per chapter as they arrive.
  - Then encode and chapter through the editor's renderer: an AAC M4B or M4A with a chapter per heading, or MP3 with ID3 chapters (FMT43, L, impact 5, the user's wish).
- **The rate:** the reader renders at a fixed utterance rate and applies the book's speed in its engine. An export either sets the utterance's rate and pitch from the book, or runs the engine's time-pitch unit offline so the file sounds exactly as the reader does (question 17).
- **Speed, with `say -o` as a proxy** on a 504-word text, the AIFF files deleted afterwards (verified):
  - Samantha rendered 100.5 s of audio in 1.68 s (60 times real time), and in 5.45 s on a second run (18 times).
  - Alex rendered 199.7 s in 3.02 s (66 times), and Daniel 166.6 s in 1.30 s (128 times).
  - So a 10-hour book takes about 5 to 35 minutes. `AVSpeechSynthesizer.write` itself was not timed.
- **Disk:** 16-bit mono at 22,050 Hz is 44.1 KB a second, so 1.6 GB per 10 hours. The final M4B at 64 kbit/s is about 290 MB. Check free space first, hold a power assertion, and keep finished chapter files so a stopped export resumes (question 19).
- **Voices:** Personal Voice is reported unable to render to buffers, defaulting to the speakers, which would speak the book aloud during an export (one Apple Developer Forums report, thread 736148). Refuse it in the export, and test before shipping.
- **The licence** (macOS Software License Agreement, section F, "Voices", read by the lead in the copy on this Mac): system voices may be used "to create your own original content and projects for your personal, non-commercial use", and "No other creation or use of the System Voices ... is permitted by this License, including but not limited to the use, reproduction, display, performance, recording, publishing or redistribution of any of the System Voices ... in a profit, non-profit, public sharing or commercial context." So the dialog should carry one plain line under the audio choices (question 20). For the same reason no kept sample holds system-voice speech.
- **Stage 2** (FMT44, L, impact 4) adds WAV, AIFF, CAF with markers, Apple Lossless, FLAC, a selection from the reader, resuming, time and disk estimates, and RF64 beyond 4 GB.

### 7.6 Audio to audio

- **Formats** (verified on files made here):
  - `afconvert` writes FLAC, and Opus in CAF and MP4.
  - It fails to write Opus, FLAC, or Vorbis in Ogg ("ExtAudioFileWrite failed ('pck?')" and "('fmt?')"). Apple has no Vorbis encoder.
- **Chapters:**
  - MPEG-4 and MP3 chapters exist in the editor.
  - WAV, AIFF, and CAF can hold markers: `AudioFileSetProperty` with `kAudioFilePropertyMarkerList` succeeded on all three, writing cue and adtl, MARK, and mark chunks with the names, and ffprobe read the WAV's markers back (verified). The editor's warning can go (FMT11, S, impact 2).
  - FLAC needs TextMouth to write its Vorbis comment block (`CHAPTERnnn`, `CHAPTERnnnNAME`, title, artist), about 100 lines (FMT39, M, impact 2).
- **Books:** an audiobook converts in Export through the editor's renderer, and a book of tracks exports as one file with a chapter per track, or as its tracks converted (FMT30, M, impact 3, the user's wish).

### 7.7 Not worth doing

- **Formats:** DAISY export (EPUB 3 does the job), DRM formats, WMA writing, Matroska writing, and Ogg Opus and Vorbis writing (an Ogg muxer or libvorbis for little use).
- **Other:** RTFD as an export (a folder), and bundling ffmpeg for export.

## 8. The other assistants' suggestions, weighed

### ChatGPT

- **M3U, then PLS:** sound. Its "allow importing an ordinary folder" is done already (Import Folder…, October 14).
- **SRT and WebVTT, with Podcasting 2.0 JSON:** sound. Whether a transcript shows on macOS 14 and 15 is untested.
- **CUE sheets and chapters JSON:** sound. Its "plays M4B versus preserves chapters" is true: `chpl`-only files show none today.
- **OPML:** it exists already; only folders are missing.
- **WebM and Matroska with track selection:** sound. Stream copying applies only to AAC tracks.
- **RTF, RTFD, and ODT through NSAttributedString:** reading holds, but headings are lost.
- **Audacity labels:** sound.
- **CAF and lossless masters:** the editor already exports Apple Lossless, WAV, AIFF, and CAF.
- **EPUB 3 Media Overlays:** sound, and an L.
- **WMA, AMR, and AVI later:** AMR and AVI with PCM are read by Apple already; WMA needs ffmpeg.
- **The Ogg correction:** right. TextMouth refuses Ogg FLAC today, so no lossless source is made lossy yet.

### Gemini

- **Loose:** WMA "extremely common" (plausible, unverified); WebM as "the standard" web audio container; CAF "eliminates 4 GB limits" (true of the format, which uses 64-bit sizes, inferred).
- **Sound:** AMR from phones (and Apple reads it); APE and WavPack cue sheets in tags (inferred); BWF (EBU Tech 3285; Core Audio reads its cue markers and ignores `bext`); CAF and crash safety (mostly true: a data chunk size of -1 is allowed when the audio chunk is last, per Apple's specification, verified); CUE, M3U, PLS, XSPF, LRC, TTML, and RTF.
- **Unwise or overstated:** Speex (obsolete); Audacity projects; EDL "essential"; oTranscribe "the de facto standard"; OverDrive .odm (retired, DRM).
- **Already working:** OPML, and Ogg Opus voice notes.

### Claude

1. **NSAttributedString formats, "Easy":** reading holds, but headings are lost and HTML needs the main thread: realistically S to M.
2. **BRF with liblouis, "Medium":** it holds only with a library. Its raw-cells mode has no macOS route, and Braille Access already shows the cells.
3. **NIMAS, "Easy":** it holds for packages; a loose DTBook file is the gap.
4. **FB2, "Easy":** S to M.
5. **MOBI and AZW3:** "KF8 is basically HTML" is half true, since most free files are MOBI 6.
6. **PowerPoint, "Medium":** right.
7. **CSV "nearly free":** half true.
8. **Images, "Easy":** S to M (transparency, orientation, memory).
9. **Comics:** CBZ is easy after images, but real CBR is not.
10. **Email, "Medium":** about 850 lines, an L here.
11. **SSML on macOS 13:** true, but "precisely" overstates. PLS in EPUB 3 appears only in an example.
12. **CUE, "Easy":** right for one file; mismatched FILE names need care.
13. **Playlists:** right, telling HLS apart.
14. **WMA:** "licensing and bundling" is avoided with the installed ffmpeg.
15. **WebM and Matroska:** "Opus in WebM is what most YouTube downloads produce" is loose (YouTube also serves AAC in M4A). Chapters as headings is verified.
16. **CAF and AMR, "Easy":** true; both are read by Apple.
17. **Lossless extras:** through ffmpeg.
18. **MIDI and trackers:** AVMIDIPlayer only plays, so rendering needs a sequencer; libopenmpt is not in Homebrew's ffmpeg.
19. **Podcast transcripts "highest-value":** half true.
20. **EPUB 3 Media Overlays:** mostly true, with the `parseTime` gap.
21. **LRC and Audacity labels, "Easy":** true.
22. **OPML:** done already, apart from folders.

Its top five map to FMT23 and FMT25 (transcripts), FMT13 (the Apple formats), FMT24 (CUE), and FMT20 and FMT21 (BRF); its sixth, OPML, exists.

## 9. Sample files

- **Where:** `TestData/format-samples/<format>/`, 148 files and 3,451,340 bytes in 74 folders, listed in `TestData/format-samples/samples.tsv`. Its columns are format, file, source, licence, size, SHA-256, and what a test would check. The largest file is 205 KB.
- **No test reads them yet:** the suite lists its TestData books by name, so nothing changes until a test names a sample.
- **Made on this Mac (138 files, CC0):**
  - Text written by the workers, or public-domain text such as Pride and Prejudice's first chapter from Project Gutenberg number 1342.
  - Made with `textutil`, `afconvert`, Homebrew's `ffmpeg`, `flac`, `metaflac`, `speexenc`, `pandoc`, `cupsfilter`, `sips`, `tiffutil`, and the workers' own Python scripts.
  - **Every audio sample is generated tones,** never `say` output, for the licence reason in section 7.5. Each source cell names the command or the generator script, `scripts/<family>/<name>`; the scripts stayed in the session's scratchpad and are not kept.
- **Synthetic files,** marked in the table:
  - a .dot with the template bit set;
  - .dotx, .docm, and .dotm repackaged from a .docx;
  - a MOBI with its DRM field set;
  - and a MOD written to the ProTracker layout, which no player here could check.
- **Downloaded (10 files, each inspected only by `file`, `shasum`, and size, and read only by `python3 -I`):**
  - Nine from LibreOffice's core repository test folders, under its MPL 2.0, with no per-file notice found: two Word-format .doc files with Heading 1 to 6 and outline levels, a .dot, a .dotx, a .docm, a .dotm, two Pages files (versions 4 and 5), and a WordPerfect 6 file.
  - One Project Gutenberg MOBI (The Yellow Wallpaper, ebook 1952), in the US public domain, its licence text inside.
  - The MPL asks that recipients be told the licence and where to get it: the licence column gives its URL.
- **By URL only (unclear licence or too big):**
  - FFmpeg's test samples: https://samples.ffmpeg.org/A-codecs/WMA9/ (WMA Pro and Voice), https://samples.ffmpeg.org/A-codecs/lossless/luckynight.wma and luckynight.ape (about 6 MB each), and https://samples.ffmpeg.org/A-codecs/musepack/.
  - libmobi's tests (LGPL 3 repository, per-file licences unclear): https://github.com/bfabiszewski/libmobi/tree/public/tests/samples (`sample-ncx.mobi`, `sample-unicode-huffdic.mobi`, `sample-drm-v1.mobi`).
  - The IDPF EPUB 3 samples (CC BY-SA 3.0 unless a sample says otherwise; the Media Overlays books are several MB): https://github.com/IDPF/epub3-samples.
  - The eBraille sample linked from https://daisy.org/ebraille (licence unknown).
  - Real braille books from BARD (https://nlsbard.loc.gov), Bookshare (https://www.bookshare.org), and APH (https://www.aph.org), which need accounts.
- **No sample at all:** AZW3, CHM, Keynote, Numbers, CBR, XLS, DjVu, XPS, APE, Musepack, DSD, and WMA Pro, Lossless, and Voice.
- **Worth keeping from the scratchpad**, if the orchestrator wants them: the braille prototype, `scripts/braille/ueb.py` (encoder, layout, BRF and PEF writers, reader, Grade 1 decoder) with `verify_samples.py` (57 checks); the .doc heading prototype, `scripts/text/docheadings.py`; and the export prototypes, `scripts/export/mkepub.py` and `mkoffice.py`.

## 10. Findings outside the request

- **SMIL timecounts read as 0:** `DAISYParser.parseTime` (`TextMouth/Parsers/DAISYParser+Audio.swift`, line 129) returns 0 for "500ms", "2min", or "1.5h". DAISY 3 books that write clip times that way would place their clips at the start (verified by reading the code).
- **Nero `chpl`-only M4B files show no chapters** (verified with a probe; FMT05).
- **`TextFileDecoder` garbles legacy encodings silently** (FMT16).
- **The user documentation's "sounds no worse"** for converted Ogg is not true in general (section 4.7).
- **Ogg FLAC could be accepted:** `afconvert` turns it into Apple Lossless (FMT14).
- **The audio editor's warning** that WAV, AIFF, and CAF drop chapters is unnecessary: Core Audio writes markers into all three (FMT11).
- **Apple bugs worth knowing:**
  - Every SSML `emphasis` element crashed `AVSpeechSynthesizer.write` (macOS 26.3.1).
  - Vision reads nothing from text on a transparent background.
  - Personal Voice is reported not to render to buffers.
  - swift-markdown 0.9.0's `HTMLFormatter` does not escape text.
- **ZIP paths:** whether TextMouth's ZIP extraction guards against `../` in entry names was not checked. Any new ZIP-based format (EPUB with Media Overlays, ODT, PPTX, XLSX, CBZ, eBraille) should resolve every path inside its package.

## 11. What could not be verified

- **Never opened elsewhere:** no sample in Word, LibreOffice, Keynote, Numbers, Apple Books, a braille display, or an embosser; no real Word-written .doc or RTF through textutil (downloads may not be opened by Apple's tools).
- **Not run:** whether `AXBrailleTranslator` serves tables to an app bundle; liblouis itself (not installed), its back-translation accuracy, its table load time, and its thread safety.
- **Untested:** VoiceOver's handling of literal Unicode braille on macOS; any real .brl file; BANA's numeric indicator on page numbers.
- **Not measured:** a minimal ffmpeg's size; Apple's rarer decoders on hostile files; whether ffmpeg is fuzzed by OSS-Fuzz; APE, Musepack, DSD, and WMA Pro, Lossless, and Voice decoding; ASF markers as chapters.
- **Not timed or tested:** `AVSpeechSynthesizer.write`'s speed and output format, and Personal Voice's behaviour on this Mac; MIDI offline rendering.
- **From experience or secondary sources only:** CUE syntax (the pages were blocked), XSPF's and TTML's media types, oTranscribe's timestamp markup, and Signal's and Telegram's voice-note formats; RTF 1.9.1's and ODF 1.3's wording on outline levels (samples were built to match).
- **Not checked:** whether a saved transcript shows on macOS 14 and 15, and whether TextMouth's ZIP extraction rejects `../` paths.
- **Patent dates** are all secondary sources, and WMA's status is unknown.
- **Licences from memory:** antiword's and catdoc's; the LibreOffice and libmobi test files' per-file licences (repository licences only).

## 12. Questions for you

Each has its context and a recommended answer. Answer only where you want something different.

Answer for the whole file:

### Text

1. **Reading RTF, .doc, .dot, and ODT through Apple's textutil.** TextMouth would run `/usr/bin/textutil` in a watched child process and find chapters from font sizes, since every heading style is lost on the way. Our own readers of Word's and RTF's real styles would be a larger job (FMT47).
   Recommended: yes now; write our own readers later only if headings come out wrong in your files.
   Answer: Do this for now, I would personally like the ability to keep bold and other formatting if possible for non heading text in case one day we might want to add the ability to speak differently formatted text like with a different pitch or something.

2. **Text files in other encodings.** Today a Russian, Central European, Mac Roman, or Japanese text file is read silently as Western text, garbled.
   Recommended: guess the encoding, say the guess in Book Info, and add a Reopen with Encoding command; no question at each import.
   Answer: yes no question at import, if its possible maybe write something to guess if the encoding can not be decoded and show a alert when opening a book to ask if its a different encoding (try guessing first). Also I noticed when trying to open a DRMed epub I had accidentally loaded that it ended up garbled... We won't put any tools to break it or anything in TextMouth of course but it might be good to show a alert when opening a garbled file alerting the user it might be corrupted or DRMed.

3. **Formats to refuse with advice.** Pages, Keynote, Numbers, WordPerfect, CHM, DjVu, XPS, real RAR comics, and copy-protected audio would get a message saying how to convert them, rather than a reader each.
   Recommended: yes.
   Answer: Why not Pages? The non Apple ones I would aggree with.

### Braille

4. **The braille in your BRF files.** UEB contracted (Grade 2), as BARD and Bookshare deliver, needs a translator to be heard as print. Uncontracted (Grade 1) TextMouth can decode itself, and older EBAE needs a translator too.
   Recommended: plan for UEB Grade 2; tell us if you have other kinds.
   Answer: It should support multiple braille tables, not sure if Apple exposes the downloaded tables to the App? Try researching braille blaster or similar tools to see how they get the tables.

5. **A library for contracted braille.** You asked for "writing the encoder and a decoder". Contracted braille needs liblouis (LGPL, about 0.6 MB, built from source in the repository as LAME is) or macOS 26's own translator, which a test program found empty. A translator of our own would take months.
   Recommended: liblouis, after a one-day test of macOS 26's translator inside the app.
   Answer: It wouldn't take months, you under estimate yourself, but I agree it would at least take a weekly limit's worth of work probably...  0.6 MB isn't bad, just go with that if thats all it adds. 

6. **Exact braille cells on your display while TextMouth speaks.** No macOS interface lets an app send its own cells to the display, and macOS 26's Braille Access already shows a BRF's cells exactly.
   Recommended: no; show the print text, and say in Book Info that Braille Access shows the cells.
   Answer: Yes, I really just want to start the brf being converted to text to be listened to and then the ability to encode to be able to convert any markdown intermediate parsed format into a braille book.

7. **BRF export defaults.** 40 cells by 25 lines, UEB Grade 2, braille page numbers on, and CR LF line ends, each changeable in the Export dialog.
   Recommended: yes.
   Answer: yes

### Audio

8. **Audio files you have.** Do you have WMA, AMR or 3GP, Matroska or WebM, or APE or WavPack files that TextMouth cannot open?
   Recommended: do the formats macOS reads first (FMT09), then WMA and Matroska; tell us any you have.
   Answer: Yes wait on those, I do see WebM more then the others on this list.

9. **Your installed ffmpeg for formats macOS cannot read.** WMA, Matroska, WavPack, and the rest would convert only when ffmpeg is installed, as yours is from Homebrew, with a clear message otherwise. Bundling ffmpeg would add about 1.5 to 3 MB and a source obligation.
   Recommended: installed ffmpeg only, for now.
   Answer: How much would it be to add the encoding / decoding for all these formats? It might be worth it to add, it looks like my current install of Text Mouth is 18.3 mb and I think I said I wanted to keep it below 30 mb if possible? Try measuring it using a test build.

10. **Lossless sources and originals.** Convert lossless sources (FLAC in Ogg, APE, WavPack, WMA Lossless) to Apple Lossless instead of AAC, and keep each original beside its converted file (it costs disk space), with the documentation corrected to say a second lossy encoding can lose quality.
    Recommended: yes to both; keeping originals as a setting, on by default.
    Answer: Yes but keep originals as off, I don't think most people would need it especially sense the file loaded into the app would still probably exist unless deleted.

### Playlists, cue sheets, and transcripts

11. **Playlists and cue sheets that name files elsewhere.** TextMouth is not sandboxed, so a playlist could name any file on the Mac.
    Recommended: use only files inside the playlist's own folder, and say which entries were skipped.
    Answer: Yes for now, maybe let adding trusted folders like ~/Music or something?

12. **Transcripts from outside.** An SRT or WebVTT file, or a podcast's own transcript, would attach to an existing audiobook (paired by file name, chosen by a command, or fetched with a feed episode), with no transcript-only import.
    Recommended: yes.
    Answer: yes

13. **A podcast's own transcript and chapters.** When a feed links them, TextMouth would download them with each episode, under the download's network rules, so an episode has text and headings at once.
    Recommended: yes, on by default.
    Answer: yes

14. **OPML folders.** An OPML import would keep the folders your podcast app wrote, as feed folders, and an export would write them.
    Recommended: yes, after the transcript work.
    Answer: yes, add a import button to the add feed sheet too.

### Other documents

15. **How a spreadsheet or CSV row reads.** One line per row, with cells separated by commas, or "column name: value" for every cell.
    Recommended: one line per row with commas, and a setting that says the column name before each cell.
    Answer: yes for now.

16. **SSML and pronunciation lexicons.** Import SSML files as plain text, and a lexicon's aliases as substitution rules, leaving IPA pronunciations and Apple's SSML speech for later: it crashed on emphasis, ignores aliases, and turns off your speed controls.
    Recommended: yes.
    Answer: yes

### Export

17. **The speed of exported speech.** It can sound exactly as the reader does, with your rate and pitch built in, or be spoken at the voice's normal rate, so you change speed in the player.
    Recommended: as the reader does, with the rate named in the dialog.
    Answer: put the rate and pitch in the dialog as sliders set to the current rate.

18. **What "part of a text book" means.** The choices would be the current chapter, a range of headings from one to another, or the text selected in the reader.
    Recommended: all three, in one Range choice; the selection comes in the second stage (FMT44).
    Answer: headings / chapter ranges, and then I was thinking like timestamp to timestamp.

19. **Resuming a long speech export.** A 10-hour book may take 5 to 35 minutes and 1.6 GB of temporary space; keeping finished chapter files lets a stopped export resume.
    Recommended: yes, deleted when the export finishes.
    Answer: Yes, and think about how to optimize this.

20. **The licence line for exported speech.** Apple's licence allows audio made with the Mac's voices for your personal, non-commercial use only.
    Recommended: one plain line under the audio choices in the Export dialog, with nothing to tick.
    Answer: yes

21. **The order of text export formats.** EPUB 3, then DOCX and RTF, with HTML along the way (it comes first, as the base) and PDF last.
    Recommended: yes.
    Answer: Yes, I thought markdown was the base, has that changed?
