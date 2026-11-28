# Brief: the Word 97-2003 reader (FMT47, .doc and .dot), agent `docreader`

Follow `Scripts/agents/briefs/2026-11-04/readers-common.md` first; this brief adds your task.

- **Slug:** `docreader`.
- **Branch:** `git checkout -b readers/doc core/own-readers`. Your worktree may start elsewhere, so name the base.

## The task

TextMouth's own reader of Word 97-2003 documents (.doc, and its template .dot), in both apps, so that "formatting extraction is under our control" (the user, November 4). It reads:
- the text;
- the real heading styles: Heading 1 to 9, and paragraph outline levels, which textutil's reading loses, guessing headings by font size;
- bold and italic: the user wants "the ability to keep bold and other formatting if possible for non heading text";
- tables;
- page breaks.

Read first:
- `FORMAT-LIBRARIES-RESEARCH-2026-11-04.md`, Part 1, "Word 97-2003";
- `TextMouth/Parsers/OwnDocumentReaders.swift`, `TextutilDocumentReader.swift`, and `TextutilPageBreaks.swift`, by line range: how textutil's reading of .doc gives the reading text, and the HTML and page contract your reader meets.

The specifications, free to implement under Microsoft's Open Specification Promise:
- [MS-CFB], https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b;
- [MS-DOC], https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/ccd7b486-7881-484c-a137-51170af7cc22;
- [MS-OLEPS], for the SummaryInformation stream's title and author.

Maps of the algorithm, read only (never copy):
- Apache POI's HWPF (Apache 2.0, the most complete);
- word-extractor (MIT, JavaScript: the FIB and the piece table);
- rust-cfb (MIT) and OLEKit (Apache 2.0, Swift) for the compound file.

## The readers, in this order, a commit or more each

1. **The compound file** (`TextMouth/Parsers/CompoundFile*.swift`). It works on `Data` and returns a stream's bytes by name. It reads:
   - the header: the signature `D0 CF 11 E0 A1 B1 1A E1`, version 3 or 4, the sector shift (9 or 12) and the mini sector shift (6);
   - the DIFAT, with the header's 109 entries and its chain;
   - the FAT and the mini FAT;
   - the directory, read as a red-black tree but walked iteratively;
   - the mini stream, and the 4096-byte cutoff below which a stream lives there.

   It guards against hostile files:
   - every sector index is checked;
   - every chain stops at a cycle, or at more sectors than the file holds;
   - every stream is held to its declared size and to the file's.

   It is shared code, so it could serve legacy .xls one day.
2. **The FIB** (in WordDocument).
   - `wIdent` 0xA5EC.
   - `nFib`. Word 6 and Word 95 files (`wIdent` 0xA5DC, or `nFib` below 101) are not this reader's: return nil from the router for them. The Mac's textutil reads them, and iOS then says the format "is not available on iPhone yet" through the existing stand-in.
   - `fWhichTblStm`, which chooses 0Table or 1Table.
   - `fEncrypted` and `fObfuscated`: throw `PasswordProtectedDocument`, as the textutil reader does today (`TextutilSourceCheck.isEncryptedWordDocument` already refuses before the router is asked, so check that the two agree).
   - `fComplex`.
   - The FibRgFcLcb's offsets, each checked against its stream.
3. **The text through the piece table** (the CLX in the table stream).
   - Each piece's text is either 8-bit Windows-1252 (fCompressed) or UTF-16LE.
   - Paragraph marks (0x0D) end paragraphs, 0x07 ends table cells and rows, 0x0C is a page or section break, and 0x0B is a line break.
   - In a field (0x13 begin, 0x14 separator, 0x15 end), keep the result and drop the instruction. Fields nest: keep a stack.
   - Drop the object and picture characters (0x01, 0x08) and footnote and annotation references (0x02, 0x05), and say in your report what textutil does with each, as your comparison shows.
4. **Styles and headings.**
   - The STSH style sheet gives each style's built-in identifier: sti 1 to 9 are Heading 1 to 9.
   - Paragraph properties come through the PlcBtePapx and its FKPs: the istd, and `sprmPOutLvl`, an outline level that makes a heading of any style.
   - A heading is `h1` to `h6`, levels 7 to 9 being `h6`. Read how the DOCX reader names its headings' levels (`DOCXParser+Styles.swift`) and match it, so a .doc and a .docx of one document read alike.
5. **Bold and italic** through the PlcBteChpx and its FKPs: `sprmCFBold` and `sprmCFItalic`, including the style's own character properties, and the toggle rule ([MS-DOC] 2.6.1, the values 0x80 and 0x81). Write them as `strong` and `em`.
6. **Tables.** Cells and rows from 0x07 with `sprmPFInTable` and `sprmPFTtp`, written as `table`, `tr`, and `td`.
7. **Pages.**
   - Explicit page breaks and page-starting section breaks (`sprmSBkc` in the SEPX of the PlcfSed) are each a page break.
   - The pages are written by `OwnDocumentReaders`' rule, which is textutil's. Check page-breaks.doc against the textutil reader's pages, test by test.
8. **The title and author** from the SummaryInformation property set: PIDSI_TITLE (2) and PIDSI_AUTHOR (4), in the head.
9. **The router.** Add `case .doc:` to `OwnDocumentReaders.html(of:as:includesPages:)`, behind `WordDocumentReader.isOn` (the common brief's switch), returning nil for a file this reader leaves to textutil (Word 6 and 95).
   - Another agent adds RTF's case to the same switch, so change only your line.
10. **The comparison** with textutil on the Mac, on every sample in `TestData/format-samples/doc/` and `dot/`, as the common brief says. Report it sample by sample.
11. **The switch commit**, if the comparison allows it, as the common brief says. Give `.doc` its own case in `PageReaderVersions`, at "1.1.0"; the other textutil formats stay at "1.0.0".

## Tests

- Every sample in `doc/` and `dot/`:
  - the LibreOffice samples' Heading 1 to 6 found, at their levels;
  - headings.doc's text;
  - page-breaks.doc's pages;
  - the templates read as documents.
- **Synthetic files,** made in code or by a script under `Scripts/` (CC0, listed in samples.tsv):
  - an encrypted one (fEncrypted set): refused with `PasswordProtectedDocument`;
  - a Word 95 one (the FIB changed): left to textutil, the router returning nil;
  - a fast-saved one (several pieces), if you can make one;
  - bold and italic runs.
- **Hostile compound files and FIBs,** as the common brief lists:
  - a FAT chain cycle;
  - a sector index past the end;
  - a directory entry's stream size of 0xFFFFFFFF;
  - a piece table whose offsets leave the stream;
  - a style index past the style sheet;
  - an FKP whose run offsets leave its page.

**Train request:** your test classes, `TextutilPageTests`, `OnDiskContractTests`, `PagesUpgradeTests`, and the `import` area.

## Your files

- New: `TextMouth/Parsers/CompoundFile*.swift`, `TextMouth/Parsers/WordDocument*.swift`, `TextMouthProductionTests/CompoundFile*Tests.swift`, `TextMouthProductionTests/WordDocument*Tests.swift`, and samples and scripts as above.
- Changed: your line in `OwnDocumentReaders.swift`; in the switch commit only, `PageReaderVersions.swift` and the tests pinning it.
- Not yours: the textutil reader, `BookFormat`, and the import service. Two other agents build the MOBI and RTF readers, so stay out of `TextMouth/Parsers/MOBI*` and `RTF*`.
