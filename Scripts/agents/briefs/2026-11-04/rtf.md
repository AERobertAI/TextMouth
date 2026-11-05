# Brief: the RTF reader (FMT47, .rtf and .rtfd), agent `rtfreader`

Follow `Scripts/agents/briefs/2026-11-04/readers-common.md` first; this brief adds your task.

- **Slug:** `rtfreader`.
- **Branch:** `git checkout -b readers/rtf core/own-readers`. Your worktree may start elsewhere, so name the base.

## The task

TextMouth's own reader of Rich Text Format (.rtf, and the TXT.rtf inside an .rtfd package), in both apps, so that "formatting extraction is under our control" (the user, November 4). It reads:
- the text;
- the real heading styles: the style sheet's "heading 1" to "heading 9" and `\outlinelevel`, which textutil's reading loses, guessing headings by font size;
- bold and italic: the user wants "the ability to keep bold and other formatting if possible for non heading text";
- lists;
- tables;
- page breaks.

Read first:
- `FORMAT-LIBRARIES-RESEARCH-2026-11-04.md`, Part 1, "RTF and RTFD";
- `TextMouth/Parsers/OwnDocumentReaders.swift`, `TextutilDocumentReader.swift`, and `TextutilPageBreaks.swift`, by line range: how textutil's reading of RTF gives the reading text, and the HTML and page contract your reader meets;
- `TextMouth/Services/Export/RTFExportWriter.swift`, TextMouth's RTF writer, whose output your reader must read back well. Stay out of it otherwise.

The specification is Microsoft's RTF 1.9.1 (2008), free to implement under the Open Specification Promise. Find a copy; Microsoft cites https://go.microsoft.com/fwlink/?LinkId=120924.

Maps, read only (never copy):
- rtf-parser (Rust, MIT): https://github.com/d0rianb/rtf-parser;
- rtf.js (JavaScript, MIT): https://github.com/tbluemel/rtf.js;
- striprtf (Python, BSD-3-Clause): https://github.com/joshy/striprtf.

## The reader (`TextMouth/Parsers/RTF*.swift`, one concern per file)

1. **The tokenizer.**
   - It reads groups `{ }`, control words (letters, an optional signed number, and the space that ends them, which is swallowed) and control symbols: `\\`, `\{`, `\}`, `\~` (a no-break space), `\-` (optional hyphen, dropped), `\_` (a no-break hyphen), and `\*` (an ignorable destination).
   - `\'hh` is a byte in the current code page.
   - `\uN` takes N as a signed 16-bit number, adding 65536 when it is negative, and then skips `\ucN` characters, kept per group, default 1. Read two `\u`s in a row as a surrogate pair.
   - `\binN` skips N bytes, with N checked against the data.
   - Group depth is capped (say 10,000), with a stack of your own, never recursion.
   - A file that is unterminated or unbalanced still yields its text so far, as textutil's reading does. Check that on a sample.
2. **The character sets.**
   - `\ansi`, `\mac`, `\pc`, `\pca`, and `\ansicpgN` give the document's code page.
   - The font table's `\fcharsetN` gives a font's code page, which applies in its runs (`\fN`).
   - Map them to Foundation encodings (CFStringEncoding through `String.Encoding`). Look for TextMouth's own code-page helpers first: `grep -rn "CFStringConvertWindowsCodepageToEncoding\|windowsCP" TextMouth`.
3. **Destinations.**
   - **Read** the style sheet (`\stylesheet`): each `\sN` with its name and `\outlinelevelN`. A name "heading 1" to "heading 9", in any capitals, or an outline level, makes a heading style.
   - **Read** `\info` for its `\title` and `\author`.
   - **Read** `\field` for its `\fldrslt` alone.
   - **Skip** `\fonttbl` (once its charsets are read), `\colortbl`, `\pict`, `\object`, `\header` and `\footer` and their variants, and every `\*` destination you do not know.
   - **Footnotes** (`\footnote`): do what textutil's reading does with them, which your comparison shows. Say which in your report.
   - **Lists:** `\listtext` and `\pntext` hold the number or bullet a list item shows. Write the items as `li` in `ul` or `ol` (bullet or number), dropping that text from the item's words. Check how `word-list-table.rtf` reads in textutil's reading, and match its words.
4. **Paragraphs and runs.**
   - `\pard` resets the paragraph's properties and `\par` ends it.
   - `\sN` gives its style, and so its heading level, `h1` to `h6` with levels 7 to 9 as `h6`. Read how the DOCX reader names its headings' levels (`DOCXParser+Styles.swift`) and match it.
   - `\outlinelevelN` on the paragraph itself makes a heading too.
   - `\b`, `\b0`, `\i`, and `\i0` become `strong` and `em`; `\plain` resets them.
   - `\line` is a line break and `\tab` a space.
   - `\page`, and `\sect` with a section break that starts a page (`\sbkpage`), are page breaks, written by `OwnDocumentReaders`' rule, which is textutil's. Check page-breaks.rtf against the textutil reader's pages.
   - Tables: `\trowd` … `\cell` … `\row`, with `\intbl`, written as `table`, `tr`, and `td`.
5. **The title and author** from `\info`, in the head.
6. **RTFD.** An .rtfd is a folder. Read its `TXT.rtf`, and leave its attachments; `\NeXTGraphic` names an attachment, which is dropped like a picture.
7. **The router.** Add `case .rtf, .rtfd:` to `OwnDocumentReaders.html(of:as:includesPages:)`, behind `RTFDocumentReader.isOn` (the common brief's switch).
   - The textutil reader sends a .doc whose bytes begin as RTF here too. Test that with a copy of an RTF sample named .doc.
   - Another agent adds the .doc case to the same switch, so change only your line.
8. **The comparison** with textutil on the Mac, on every sample in `TestData/format-samples/rtf/` and `rtfd/`, and on RTF that `RTFExportWriter` writes, as the common brief says. Report it sample by sample.
9. **The switch commit**, if the comparison allows it, as the common brief says. Give `.rtf` and `.rtfd` their own case in `PageReaderVersions`, at "1.1.0"; the other textutil formats stay at "1.0.0".

## Tests

- Every sample in `rtf/` and `rtfd/`:
  - word-styles.rtf's Word headings;
  - headings.rtf's text (textutil's own RTF, with sizes only);
  - page-breaks.rtf's pages;
  - word-list-table.rtf's lists and table;
  - with-image.rtfd's text without its picture.
- **Synthetic RTF in code:**
  - `\u` with negative values and `\uc2`;
  - `\'hh` in Windows-1251 through `\ansicpg1251` and a `\fcharset204` font;
  - a field's result;
  - an ignorable unknown destination;
  - nested groups that set and reset bold.
- **Hostile RTF,** as the common brief lists:
  - 100,000 nested `{`;
  - a `\bin` longer than the file;
  - an unterminated group;
  - an invalid `\'`;
  - a `\u` of 99999999;
  - a megabyte of control words.

**Train request:** your test classes, `TextutilPageTests`, `OnDiskContractTests`, `PagesUpgradeTests`, the `import` area, and the `export` area (your reader must read the RTF writer's output).

## Your files

- New: `TextMouth/Parsers/RTF*.swift` (not `RTFExportWriter.swift`), `TextMouthProductionTests/RTF*ReaderTests.swift`, and samples and scripts.
- Changed: your line in `OwnDocumentReaders.swift`; in the switch commit only, `PageReaderVersions.swift` and the tests pinning it.
- Not yours: the textutil reader, `BookFormat`, and the import service. Two other agents build the MOBI and .doc readers, so stay out of `TextMouth/Parsers/MOBI*`, `WordDocument*`, and `CompoundFile*`.
