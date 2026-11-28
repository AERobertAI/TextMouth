# Brief: the MOBI reader (FMT42), agent `mobireader`

Follow `Scripts/agents/briefs/2026-11-04/readers-common.md` first; this brief adds your task.

- **Slug:** `mobireader`.
- **Branch:** `git checkout -b readers/mobi core/own-readers`. Your worktree may start elsewhere, so name the base.

## The task

Import DRM-free MOBI books (Mobipocket, the older Kindle format) into the reading text, in both apps, as a new book format. The user asked for ".mobi" import "to at least import them and convert them to the intermediate reading format". AZW3 (KF8) is the next task (FMT48), not yours: recognize it and refuse it, as below.

Read first:
- `FORMAT-LIBRARIES-RESEARCH-2026-11-04.md`, Part 2, "MOBI 6" and "AZW3 (KF8)";
- the reference implementation: foliate-js's `mobi.js` (MIT, verified), https://github.com/johnfactotum/foliate-js/blob/main/mobi.js, read for the algorithm only;
- the MobileRead wiki's MOBI page, if it answers you (it refused this Mac's connections today);
- go-richdoc/mobi's README (BSD-3-Clause), https://github.com/go-richdoc/mobi, a plain account of the failure modes.

## The format and its wiring

**The format.** A new `BookFormat` case `mobi`, raw value `"mobi"`:
- display name "Kindle Book (MOBI)";
- extensions `mobi`, `prc`, and `azw`.

**The wiring.** Find every place a format is wired by following the last formats added: `grep -rn "\.webarchive\b\|\.ssml\b" TextMouth --include='*.swift'`, and the compiler will list each `switch` that must handle the new case. Among them:
- `BookParser`;
- `MarkdownCacheService`'s extraction;
- `FileImportService`'s import, its title and author, and its allowed file types (`UTType(filenameExtension:)`);
- `LibraryBookInfoLoader`;
- the document types in `TextMouth/Resources/Info.plist`, so Finder opens a .mobi with TextMouth.

**An older TextMouth.** It cannot read a library index that holds a book of a new format (0.2.0's eight formats were the same).
- `OnDiskContractTests.testEveryBookFormatIsSavedUnderItsOwnName` pins the formats. Update it deliberately, with a comment saying so.
- The orchestrator raises the version's MINOR and writes the caution in the changelog. Change no version yourself.

**No pages.** MOBI has no print pages; an APNX file beside a book would hold them, and that is a later item. `PageReaderVersions.current(for: .mobi)` stays nil.

## The reader (`TextMouth/Parsers/MOBI*.swift`, one concern per file)

1. **The Palm database.**
   - The header gives the database name (bytes 0 to 31) and the type and creator at 60 to 67: `BOOKMOBI`, or `TEXtREAd` for a plain PalmDOC .prc.
   - The record count is at 76, and the record entries start at 78, 8 bytes each, the first 4 being the record's offset.
   - Check every offset: ascending, inside the file, records not overlapping.
2. **Record 0.**
   - The PalmDOC header: compression at 0 (1 none, 2 PalmDOC, 17480 HUFF/CDIC), the text length at 4, the text record count at 8, the record size at 10, and encryption at 12.
   - The MOBI header, from 16 (`MOBI`): its length at 20, the encoding at 28 (65001 UTF-8, 1252 Windows-1252), the version at 36, and the EXTH flag (bit 0x40 at 128). Also the DRM offset, count, size, and flags at 168 to 180 (0xFFFFFFFF for none), the extra-data flags at 240 (the low 16 bits), and the NCX index record at 244.
   - **EXTH:** 100 author, 503 title, 524 language, 101 publisher, 104 ISBN, and 121 the KF8 boundary.
3. **Refusals** (typed errors, sentences settled here):
   - **Encryption field not 0, or a DRM offset that is not 0xFFFFFFFF:** "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." TextMouth never removes copy protection, and no code may try.
   - **A KF8-only book** (MOBI version 8 with no EXTH 121, such as `TestData/format-samples/mobi/pg1952-yellow-wallpaper-kf8.mobi`): "This Kindle book is in the newer KF8 format, which TextMouth can't read yet."
   - **A hybrid file** (EXTH 121 present): read its MOBI 6 part, the first.
   - **HUFF/CDIC** (17480): implement it last, if your other work is done and checked (about 120 lines, `mobi.js` lines 265 to 325 as the map). Until then refuse: "This Kindle book is compressed in a way TextMouth can't read yet."
4. **The text.**
   - For each text record 1 to N (the PalmDOC count, capped by the record count), strip the trailing entries named by the extra-data flags:
     - for each set bit above bit 0, a variable-width size read backward from the record's end;
     - then, for bit 0, the multibyte overlap of `(last byte & 3) + 1` bytes.
   - Decompress PalmDOC LZ77 with every back reference checked. Stop at the declared text length, and refuse past an absolute cap; take `DocumentByteLimit`'s as a guide for the size.
   - Decode the text with the header's encoding, tolerating bad bytes as `TextFileDecoder` does.
5. **The HTML dialect.**
   - `<a filepos=NNN>` and `filepos` attributes name byte offsets into the decompressed text. Put an anchor `<a id="filepos-NNN"></a>` at each offset that is named before the markup is parsed, so links and the table of contents land on their words.
   - `<mbp:pagebreak/>` is a layout break, not a print page: a chapter boundary at most, never a page.
   - Drop the other `mbp:` tags and `recindex` images, keeping an image's alt text.
6. **Chapters.**
   - **With an NCX index** (INDX at the offset 244 gives, then TAGX and CNCX; `mobi.js` lines 329 to 425 as the map): its entries give each chapter's label, text offset, length, and depth. Split the HTML at the top-level entries' offsets into chapters titled by their labels, and let deeper entries become headings, the way `EPUBParser` turns a book's TOC into chapters and heading annotations (`MarkdownHeadingAnnotation`).
   - **Without one:** chapters at `mbp:pagebreak`, and headings from the markup.
   - Produce the same kind of `DocumentContent` and content.md as the EPUB reader does. Read how `EPUBParser.prepareBook` and `MarkdownCacheService` hand chapters to the cache, by line range, before designing this.
7. **Metadata.** The title and author from EXTH, else the database name, else the file's name, and "Unknown" author as other formats do. The language when given.

## Tests

- `TestData/format-samples/mobi/pg1952-yellow-wallpaper.mobi` (MOBI 6, PalmDOC, no NCX headings):
  - its text matches the book's words (its beginning and end checked);
  - the title is "The Yellow Wallpaper" and the author is Charlotte Perkins Gilman.
- `yellow-wallpaper-drm-flagged-synthetic.mobi`: refused with the sentence above.
- `pg1952-yellow-wallpaper-kf8.mobi`: refused as KF8.
- A MOBI with an NCX: make one, CC0, with calibre's `ebook-convert` from a small EPUB you write yourself. calibre is installed at `/Applications/calibre.app/Contents/MacOS/ebook-convert`; use `--mobi-file-type old`, and record the script under `Scripts/` and the file in samples.tsv. Its chapters and headings come from the NCX.
- Hostile files built in code, as the common brief lists, among them: an LZ77 back reference before the start, a record offset past the end, a text record count of 65535, and an INDX record pointing outside the file.
- Import end to end (`FileImportService`) of the sample into a sandboxed library, as other format tests do (find one with `grep -rln "webarchive" TextMouthProductionTests`).

**Train request:** your test classes, `OnDiskContractTests`, `PagesUpgradeTests`, and the `import` area.

## Your files

- New: `TextMouth/Parsers/MOBI*.swift`, `TextMouthProductionTests/MOBI*Tests.swift`, a sample script under `Scripts/`, and samples under `TestData/format-samples/mobi/`.
- Changed: the format's wiring above, `OnDiskContractTests`, and `samples.tsv`.
- Not yours: `OwnDocumentReaders.swift`, `PageReaderVersions.swift`, and the textutil reader. Two other agents are building the .doc and RTF readers, so stay out of `TextMouth/Parsers/WordDocument*`, `CompoundFile*`, and `RTF*`.
