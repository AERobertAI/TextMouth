# The October 24 tasks

Read `common.md` beside this file first. The TODO is gitignored, so read it in the main checkout at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`, by grep and line range.

## A. `braillereading` (Opus), branch `braille/reading`: braille emphasis read back for EBAE and UEB
From the braille emphasis merge's follow-ups (`grep -n "From brailleemphasis" TODO-2026-09-04.md`):
1. **An EBAE reading pass.** liblouis reads EBAE's emphasis signs wrongly, and turns some into stray periods ("an .italic word"), which BARD's EBAE books already get. Before back-translation, find EBAE's emphasis signs at word starts:
   - ⠨⠨ and ⠸⠨⠨ open a passage;
   - ⠨ and ⠸⠨ mark a word, or a passage's last word;
   - ⠠⠄ ends it;
   - liblouis's extra sign before punctuation is tolerated;
   - ⠨ inside numbers is the decimal point, and is left alone.

   Remove the signs before liblouis sees them, and map the emphasis onto the print through `lou_backTranslate`'s positions, so EBAE books read without stray periods and keep italic and bold.
2. **A UEB reading pass that knows where emphasis terminators are,** curing contracted UEB's misread contractions before an end sign ("people" back as "p"). The six pinned cases are in the round-trip tests.

Work in `TextMouthBraille/main.c` (protocol 2's header stays the one definition) and `BrailleTranslator.swift`. Leave `BrailleBookReader.swift` and `BraillePageAnalyzer.swift` to task B; if you need either, agree with `pg12` on the board.

Once reading works for EBAE, let export write EBAE emphasis again, since `check_readable` decides. Test both on every bundled table, with the EBAE samples, in both directions.

## B. `pg12` (Opus), branch `pages/braille`: braille pages, and plain text form feeds
PG12 and PG13 in the TODO's pages section, as `PAGES-RESEARCH-2026-10-21.md` designs them:
- "page" means the braille page (question 2 of `humanQuestions/2026-10-21.md`);
- the analyzer records each page's first block and cell offset;
- `BrailleBookReader.markdown` places markers between block lines, never inside one;
- braille gets its own line in `PageReaderVersions`, and the form feeds of plain text their own line.

Follow V07 (`grep -n "V07 —" TODO-2026-09-04.md`): a reader change re-reads only its own format. You own `BraillePageAnalyzer.swift`, `BrailleBookReader.swift`, `PlainTextParser.swift`, and their tests.

## C. `st04` (Opus), branch `fix/replace-existing`: Replace Existing keeps the old copy's state
ST04's carry-over (`grep -n "ST04 —" TODO-2026-09-04.md`; `PLAN-0.2.0-2026-10-23.md` §3.2 item 4). When the user replaces a duplicate, the new copy takes the old book's place in the library, keeping:
- its ID;
- its reading position and bookmarks, moved by text anchors where the text differs;
- its notes and settings;
- its folder and reading-list place;
- its transcript, when the audio is the same.

An Edit Text change is kept as a copy, never laid over different text. Then change the duplicate question's sentence (pinned in `ImportDecisionQueueTests`) to say what is kept and what is not.

You own `LibraryViewModel+Duplicates.swift` and the import paths it calls; agree on the board before touching shared files.

## D. `pagespolish` (Sonnet), branch `pages/polish`: pages follow-ups
From the TODO's pages follow-ups (`grep -n "From team pages (October 21)" TODO-2026-09-04.md`) and the October 21 notes:
1. Go to Page announces the typed label while the row names the last page at that place. Announce the page the row names.
2. A repeated label can't be reached again from the panel. Return on an unchanged label goes to that label's next page.
3. An EPUB page break's visible text inside a heading stays in its label ("Part 9Two"). Leave it out of the heading's label (`HTMLReadingText.label(of:)`).
4. PDF reads "1.100" as 1100 for "of N". A label with a period or comma is not a whole number.
5. The Page unit is offered for audiobooks and books without pages. In the playback bar's and Settings' unit pickers, leave Page out for a book without pages, while Settings' global picker keeps it.

Each fix is small, with its test. Change `PageReaderVersions` for EPUB or PDF only if reading text changes, with V02's pins.

## E. `fmt16` (Sonnet), branch `formats/encodings`: text files in other encodings
FMT16 in the TODO (`grep -n "FMT16 —" TODO-2026-09-04.md`): Mac Roman, Central European, Cyrillic (Windows-1251, KOI8-R), and Japanese or Chinese text files arrive garbled today.
- After today's UTF-8 and UTF-16 checks, guess with Foundation's `NSString.stringEncoding(for:…)`, plus a letter-frequency check for Mac Roman and KOI8-R.
- Name the encoding in Book Info ("Read as Windows-1251").
- New imports only: existing books keep their text.
- Leave the TODO's "Reopen with Encoding" command for a later step, and name it as a follow-up.

Samples: `TestData/format-samples/txt-encodings/` if present; otherwise make them in the test, from strings. You own `TextFileDecoder.swift` and `PlainTextParser.swift`'s decoding. `PlainTextParser.swift` is shared with B's form feeds: agree an order on the board.
