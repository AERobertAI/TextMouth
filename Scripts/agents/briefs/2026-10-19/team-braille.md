# Charter: team `braille` (October 19, 2026)

Read `teams-common.md` beside this file first. You are `braille-lead` (Opus), on `team/braille`.

## The request, in the user's words
- Tonight: "Go ahead and try working on the braille reading features tonight. and the export feature, for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library. (see how much it increases app size)"
- On the research's questions (October 17, `FORMATS-RESEARCH-2026-10-17.md` section 12; read sections 3 and 7.4 of that file, lines 128 to 180 and 399 to 402, and nothing else of it):
  - Q4, the braille in BRF files: "It should support multiple braille tables, not sure if Apple exposes the downloaded tables to the App? Try researching braille blaster or similar tools to see how they get the tables."
  - Q5, a library for contracted braille: "0.6 MB isn't bad, just go with that if thats all it adds."
  - Q6: "I really just want to start the brf being converted to text to be listened to and then the ability to encode to be able to convert any markdown intermediate parsed format into a braille book."
  - Q7, BRF export defaults (40 cells by 25 lines, UEB Grade 2, braille page numbers on, CR LF, each changeable in the Export dialog): "yes".
  - Q9, on size: "my current install of Text Mouth is 18.3 mb and I think I said I wanted to keep it below 30 mb if possible? Try measuring it using a test build."

## Your items (`TODO-2026-09-04.md`: read only the lines `grep -n -E "^- \[ \] \*\*FMT2[012] " TODO-2026-09-04.md` prints)
- **FMT21:** contracted and uncontracted braille through liblouis, with several tables.
- **FMT20:** reading BRF, BRL, and PEF files.
- **FMT22:** writing BRF and PEF, in two phases. Phase A, now: the page layout and the two writers, as code that takes braille and gives a file. Phase B, after team `export` merges FMT18 (the Export dialog's Convert to choice and its document walker): wiring them in. The orchestrator tells you by message when to start Phase B.

Report after Phase A, and again after Phase B. The orchestrator may merge Phase A first.

## Decisions already made (settled; do not reopen them, and say each in the code's comments where it applies)

### liblouis
1. **Vendor liblouis's latest stable release** from https://github.com/liblouis/liblouis/releases, as LAME is vendored. Read `project.yml` lines 96 to 150 (the LAME target and its notes) and `docs/developer/third-party-code.md` lines 7 to 9 first.
   - Download only the release tarball, into its own new, empty folder in the scratchpad. Record its SHA-256 in project.yml's notes. Compare its library sources with the release's git tag (`git ls-remote` and a raw file or two are enough), and say what you compared.
   - **Run nothing from it:** not `configure`, `make`, or any script. Copy into `Vendor/liblouis`, unchanged, only:
     - the library's C sources and headers (`liblouis/`), less anything only its tools use;
     - `COPYING.LESSER`, `README`, `AUTHORS`, and `NEWS`;
     - the tables the app bundles (item 4).
   - TextMouth adds a hand-written `config.h` and `liblouis.h` (from `liblouis.h.in`), and a `module.modulemap` if Swift imports it. Build with 32-bit wide characters (UCS-4, as `--enable-ucs4` would), so every Unicode character and braille cell fits.
   - It is a static library target, optimized for size (`-Os`), its warnings inhibited as LAME's are.
   - The licence is the LGPL 2.1 or later. Static linking is allowed because the app's whole source, liblouis's included, is in the repository, so the app can be rebuilt with a changed liblouis (the LAME precedent). Never copy code from liblouis's `tools/` (GPL 3).
2. **liblouis runs in a helper process, never in TextMouth's own.** It is C reading untrusted braille and text, it has had memory-safety bugs, and it is not thread-safe. A hang or a crash in it must cost one helper run, never the app or the import.
   - The helper is a small command-line target that links the library, embedded in the app bundle (`Contents/MacOS` or `Contents/Helpers`; `Bundle.main.url(forAuxiliaryExecutable:)` finds the first).
   - TextMouth runs it through `WatchedProcess` (`TextMouth/Services/WatchedProcess.swift`; `run` and `runCapturingOutput` at about lines 260 and 293), with a time limit, a memory limit, an output cap, and Cancel, as `TextutilConverter` runs textutil. Measure the helper on a large input, about 10 MB of braille made by repeating a sample, and give the limits four times that headroom.
   - The protocol is the simplest that works. One paragraph per line of UTF-8, in a file whose path is an argument, and one output line per input line, in an output file. The Swift side replaces line breaks inside a paragraph with spaces before sending. It splits a paragraph of more than about 4,000 characters at spaces (blank cells), which is safe: no UEB or EBAE contraction spans a blank cell. Modes: `back` (braille to print), `forward` (print to braille), and `check` (compile the tables and exit 0).
   - Braille travels as Unicode braille patterns (U+2800 to U+283F), in and out. Use liblouis's `ucBrl` mode and/or `braille-patterns.cti`, whichever the samples prove right.
   - The helper sets liblouis's table path to the bundle's tables folder, never a system one. One Swift type is the only caller of the helper (a `BrailleTranslator`, say), and every other file goes through it.
3. **Tests run the real helper** from the built app (the test host is the app). They round-trip the samples:
   - `TestData/format-samples/brf/pride-and-prejudice-ch1-grade1.brf` against `pride-and-prejudice-ch1.txt`;
   - `grade2-short.brf` against `grade2-short.txt` (its contractions are named in `grade2-short-contractions.txt`).
   A difference that is liblouis's own (back-translation is ambiguous) is pinned and named in the test, never hidden by loosening the comparison.
4. **Tables.** Bundle all of English, as the closure of their `include` lines: Unified English Braille (UEB) uncontracted and contracted, and English Braille American Edition (EBAE) uncontracted and contracted. BARD's older books are EBAE.
   - Tables live under the app's Resources (for example `Resources/liblouis/tables`), unchanged, with their licence headers.
   - **Measure** what each larger set would add, without bundling it: every literary table (with its includes), every table (481 files, about 13.9 MB on master), and every table compressed (`zip -9` of the folder). The user decides from those numbers; the orchestrator puts the question.
   - **The list of tables comes from the tables' own metadata,** read by TextMouth's own Swift code from the bundled files: `#-display-name`, `#-index-name`, `#+language`, `#+system`, `#+contraction` (no, partial, full), `#+grade`, `#+type`, and `#+direction`. Adding a table is then only a resource.
   - A test runs the helper's `check` on every table the list offers.
5. **Apple's tables and other tools.** Answer the user's Q4 cheaply, for the report:
   - Run one throwaway probe, never committed, inside the test host: does `AXBrailleTranslator` (Accessibility.framework, macOS 26) give an app bundle any tables?
   - Find, in primary sources (each project's repository or documentation), how BrailleBlaster and NVDA get their tables. The expectation is that both bundle liblouis's.
   This decides nothing tonight. liblouis is the route.

### Settings and the per-book code
6. **A Braille tab in Settings.** It is a new `SettingsTab` case, `braille`, titled "Braille", after `text` (`TextMouth/Views/Settings/SettingsView.swift` about lines 37 to 60). It has two pickers:
   - **"Braille code"**, the system and language, such as "Unified English Braille" and "English Braille, American Edition", grouped by language when there is more than one;
   - **"Contraction"**: "Uncontracted (Grade 1)", "Contracted (Grade 2)", and "Partly contracted" where a code has it, offering only what the chosen code's tables have.
   - The defaults are Unified English Braille, contracted (the user's Q7).
   - A caption says what they do. Draft: "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with."
   - Every control has a label, a hint, and a spoken value; `SettingsTabFitTests` passes; the wording is pinned.
7. **A book keeps the table it was imported with.** The table's identifier is stored with the book, in its package record, as an optional field that older packages lack. Every later reading of the book uses it, the Markdown cache's rebuild included. So a change of the setting never shifts an existing book's text under its positions and bookmarks.
   - Book Info shows a braille book's code and contraction, and Speak Info speaks them.
   - Reading a book again with another code is a follow-up, not tonight.

### Reading (FMT20)
8. **The formats.**
   - BRF (`.brf`, braille ASCII in pages) and BRL (`.brl`, the same characters unformatted) map each character to its cell with the fixed table in the research (section 3.2, line 139), and lowercase reads as uppercase.
   - PEF (`.pef`, and a PEF named `.xml`, found by adding PEF's root element in its namespace `http://www.daisy.org/ns/2008/pef` to `TextMouth/Parsers/XMLDocumentSniffer.swift`) gives rows of Unicode braille. It is parsed with `XMLParser`, with external entities never resolved. Its `dc:title`, `dc:creator`, and `dc:language` give the book's title, author, and language.
   - BRF and BRL books are titled by the file name.
   - Every one is refused above `DocumentByteLimit` (64 MB, `TextMouth/Parsers/DocumentByteLimit.swift`).
   - A BRF or BRL holding characters outside braille ASCII, other than CR, LF, form feed, tab, and a final Ctrl-Z, is refused by name, with the character and its line. An 8-dot file is refused too.
9. **Pages, paragraphs, and headings.** Follow BANA's Braille Formats (2016), as the research's prototype does: `Scripts/agents/briefs/2026-10-19/braille-reference/ueb.py`, read its reader functions; `verify_samples.py` beside it holds its checks.
   - **Pages:** pages split at form feeds, else every 25 lines.
   - **Page numbers:** the braille page number at the right of a page's last line, a print page number at the end of its first line, and a print page change line (a line of dots 3-6 cells ending in a number) are taken out of the text. They must never be read aloud mid-sentence.
   - **Paragraphs:** a paragraph begins at cell 3, its runover lines at cell 1. A paragraph continues across a page break.
   - **Headings:** a centered line with a blank line before and after is a level-1 heading, a cell-5 heading level 2, and a cell-7 heading level 3. The line width is measured from the file, from 18 to 80 cells.
   - **The book's text** is the back-translation, through the book's table, of each paragraph and heading, written as the Markdown the text formats make (`TextMouth/Parsers/BookParser.swift` and `TextMouth/Services/MarkdownCacheService.swift` about lines 450 to 475 dispatch by format).
   - **Navigation by braille or print page** is a follow-up. Keep each page's numbers in the parsed model, so it can come later.
10. **The format.** A new `BookFormat` case, `braille` (`TextMouth/Models/Book.swift`), for `.brf`, `.brl`, and `.pef`. Add them to the import's accepted types and to `TextMouth/Resources/Info.plist`'s document types at Alternate rank, as the October 18 formats are.
    - Say in your report that a TextMouth built before this merge cannot open a library that holds a braille book. It keeps the library's file and writes nothing.
11. **What a listener hears.** Every refusal follows the import's own words ("Could not import “X”. Reading its text failed: …"), as the October 18 formats' refusals do (`ImportFailure`):
    - "This file has no text to read." for an empty or blank one;
    - a damaged PEF, named as such;
    - the helper stopped at a limit, with `WatchedProcess.KillReason.words`;
    - a character that is not braille ASCII;
    - an unknown table.
    Pin each one in a test.

### Writing (FMT22, Phase A)
12. **Layout,** as BANA (2016) and the prototype give it:
    - 40 cells by 25 lines by default;
    - headings: h1 and h2 centered, with a blank line before and after and at least three blank cells on each side; h3 at cell 5; h4 to h6 at cell 7;
    - paragraphs in cells 3 and 1; list items in cells 1 and 3;
    - no word divided at a line's end, except a word longer than a line, which is cut at the line's end;
    - the braille page number at the right of the last line, with at least three blank cells before it;
    - a form feed between pages.
    BRF is braille ASCII with CR LF line ends; PEF is XML with its `dc:` metadata and rows of Unicode braille, valid against PEF 2008's structure (volume, section, page, row).
13. **The writers' options:** cells per line (18 to 80), lines per page, the code and its contraction (defaults from the Braille tab), braille page numbers on or off, and line ends (CR LF or LF). Defaults: 40, 25, UEB contracted, on, CR LF (Q7).
14. **Shape of the code.** The input is a list of blocks, each a heading with its level, a paragraph, or a list item with its depth, with its print text. The output is the file's bytes.
    - The layout is pure Swift, with no file or process access, so it is tested quickly.
    - The forward translation goes through the same `BrailleTranslator`.
    - Pin the samples: a book of the P&P chapter's paragraphs in Grade 1, laid out at 40 by 25, matches `brf/pride-and-prejudice-ch1-grade1.brf` and `pef/pride-and-prejudice-ch1-grade1.pef`, or each difference is named and explained.
    - Edit no `BookExport*` file in Phase A: team `export` owns them until its merge.

### Phase B (when the orchestrator says)
15. Rebase onto main.
    - Offer BRF and PEF in the Export dialog's Convert to choice, through team `export`'s writer interface (its lead leaves a note on it in `Scripts/agents/briefs/2026-10-19/export/`), with item 13's options.
    - The blocks come from team `export`'s document walker, never a second reader of `content.md`.
    - Add one round-trip test: export a book to BRF Grade 2, import it, and compare the text, naming liblouis's own differences.

## Size (the user asked)
Before the first liblouis commit, build main's Release app once with your own derived data folder through the build wrapper (`xcodebuild build -configuration Release -scheme TextMouth -project TextMouth.xcodeproj CODE_SIGNING_ALLOWED=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-braille-size`). Record:
- `du -sk` of the .app;
- the main executable's bytes.
Build again once the helper and the English tables are in, and report both, with:
- the helper's size and the tables folder's size;
- item 4's three projections.
Delete that folder after its last build, unregistering its app first.

## Files and areas
- **Yours:**
  - `Vendor/liblouis/`, the helper's sources, and `project.yml`'s new targets;
  - `TextMouth/Parsers/` new braille readers, `TextMouth/Services/` the translator and the layout;
  - `TextMouth/Views/Settings/` the Braille tab, with `SettingsView.swift`'s `SettingsTab` enum;
  - `TextMouth/Models/Book.swift`'s `BookFormat` braille case, `XMLDocumentSniffer.swift`, `BookParser.swift`, and the braille case in `MarkdownCacheService.swift`'s dispatch;
  - `Info.plist`'s braille types, the package record's optional table field, and Book Info's line.
- **Team export's:** every `BookExport*` file, `TextMouth/Views/Export/`, and the new export walker and writers. Touch none of them before Phase B.
- **Test classes:** new ones for each part. Also run `BookFormatTests`, `XMLDocumentSnifferTests` (or whatever tests the sniffer: `grep -ln XMLDocumentSniffer TextMouthProductionTests`), `SettingsTabFitTests`, `LogContentPolicyTests` if you add a log tag, and the import area (`run-area.py import`).

## The report
Teams-common's form, plus:
- the size figures;
- the answers to Q4's two questions, with their sources;
- the tables bundled, by display name;
- every new sentence, label, hint, and caption.
