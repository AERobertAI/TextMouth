# Brief: the pages review's safety fixes, before the merge (October 21, 2026)

You are `pagesfix`, an Opus agent, working on `team/pages` itself (a8e7fa2e). TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Why
A fresh Opus review of team/pages (the whole report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/review-pages-report.md`; read it first) judged that PG09, the re-reading of the user's existing books at the next launch, is **not safe yet**:
- heading-only Edit Text changes made before today look unchanged to its check, so they would be read over;
- a book it keeps as hand-changed gets no protection afterwards;
- an interrupted batch turns TextMouth's own text into a false edit.

There is not enough of the week left today to make PG09 safe. So today's merge ships pages for books imported or re-extracted from now on, with **PG09's launch re-read switched off**, and fixes the findings that would harm those books. PG09's safety fixes come in another session.

## Do these, each a small commit with its test
1. **Switch off PG09's launch re-read.**
   - Add one named switch, commented with why and with the review's findings 1, 2, 3, and 7.
   - With it off, the startup batch selects no book for pages, while new extractions still record the current page reader.
   - Keep the code and its tests: run them with the switch on through a test seam, so they stay green.
   - Add a test that, with the switch off, the batch re-reads no book for pages.
2. **Finding 4: a marker can begin a line** (`MarkdownMarkerWriter.swift:55-63`, callers `DAISYParser+TextExtraction.swift:413` and `DOCXParser+Converter.swift:991`).
   - `<li>\n  <pagenum>7</pagenum>\n  Second item words.</li>` loses those words and page 7.
   - In a quote or a heading, the marker is read aloud as code.
   - A DOCX italic "Roses", then a line break, then a page break, loses the rest of the line.

   Make every placement safe in every block context (a list item's continuation lines, block quotes, headings, after a hard break). Test the reviewer's cases, and check each output with the parser that every word survives.
3. **Finding 5: a page at a chapter's very end** (offset equal to the text's length) is clamped back onto the page before it (`BookPages.swift:46`, `ReaderViewModel+Pages.swift:193-199`, `ReaderViewModel+Navigation.swift:982`). Next Page then says "Page 5" on every press while the row says page 4; the golden `dtbook__pages-front-and-inline` has page 5 at 0:240 of 240. Make such a page navigable without looping, for example as the next chapter's start, or else passed over. Test that Next Page never repeats.
4. **Finding 8: a double space** (`HTMLToMarkdownConverter.swift:552`). After a marker, the next space is kept, so an empty page anchor between words gives "One  two", and the reading text then differs from `includesPages: false` at nearly every page of an EPUB with a page list. Make the reading text identical with and without pages, and test it on an EPUB sample with a page list.

Leave everything else in the report as follow-ups: PG09's findings 1, 2, 3, and 7, and the low findings. The orchestrator records them in the TODO.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout team/pages`, which no other worktree holds now. Register on the board as `pagesfix`, and build only through the wrapper (`run-area.py`).
- **Commits.** Small commits with tests, comments in the surrounding style, and each message ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Tests:** no traps, no sounds, no `~/.TextMouth`, and no `UserDefaults.standard`.
- **Disk.** It is tight: check for at least 4 GB free before your build, and delete your build folder at the end, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Budget.** The week is at 34% left, and today's line is 30%. Keep the run lean, with no subagents.
- **At the end,** in one `run-area.py` invocation, run:
  - MarkdownPageMarkerTests, PageModelTests, PageNavigationTests, PagesUpgradeTests, EPUBPageListTests, and DOCXPageTests;
  - the DAISY page tests;
  - TextPipelineGoldenTests, ReadingTextCacheTests, ExportDocumentWalkerTests, and every class you touch.

  Also run `make lint-tests LINT_BASE=main`. Do not run the full suite; the orchestrator runs it at the merge.
- **Never** push or merge into main.

## The report (your final message, at most 25 lines)
- Each commit, with its subject.
- How each finding was fixed, and its test.
- The exact counts and the lint result.
- Anything that changes what a listener hears.
