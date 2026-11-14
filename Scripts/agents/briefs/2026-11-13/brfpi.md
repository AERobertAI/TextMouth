# The Life of Pi braille fixes (November 13, 2026, night)

You are one of two Sonnet workers, `brfdecode` or `brflayout`; your launch message says which. First read `common.md` beside this brief and follow it. Its rules bind you: the live library, `rm` with literal paths only, no search from `/` or `~`, builds only through the heavy-work lock, trains on GitHub, no push except through the train tools, no merge into main. One more rule for tonight: **delete nothing at all.** It is a night's run.

## The user's words

"I did import a Epub and BRF of the book 'Life of Pi'. ... there do seem to be some errors in the decoded text plus the meta data is off (the brf was from BookShare) ... see if the mistakes are just like from a bad scan or something or a bug with the decoder?" Then: "have agents work on those fixes."

## What was found

Read `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/lifeofpi/report.md` first. The BRF is a 2003 Australian transcription in the old English Braille code (EBAE), 4 volumes of 40-cell rows, imported with the default UEB table. Its scripts are in that folder; you may run them, but only with `python3 -I`.

## The two books (READ ONLY, and only these two)

The user allowed reading these two packages for this work, and nothing else under `~/.TextMouth`:
- BRF: `/Users/roberteggleston/.TextMouth/Library/000058499-Unknown-1794612212-51b32e89-adb7-4a6c-a2e8-efecedb043e7.tmb/`
- EPUB: `/Users/roberteggleston/.TextMouth/Library/Life_of_Pi-Yann_Martel-1794614979-68116b86-0a4d-4499-8c85-39f451afc2cf.tmb/`

Rules for them:
- Read with read-only tools only. Never write there, and never launch TextMouth.
- **Never write the book's text or braille to any file.** Pipe a decoder's output straight into the comparison script, and keep only counts and excerpts of a few words.
- Tests use small braille samples you invent, never this book's text.

## The two parts

### `brfdecode`, branch `fix/brf-ebae-decoding`

You own the braille helper (`TextMouthBraille/main.c`) and any table overrides TextMouth ships. Fix these, one commit each, each with its test:
1. Run-together EBAE wordsigns ("ofthe", "andthe", "ofa", "witha", "forthe", "withthe"): split a blank-delimited run made only of the and/for/of/the/with/a signs into words. That includes runs touching punctuation or quotes.
2. "ing" before a hyphen reads "±".
3. `4` between letters (initials such as `P4B4U4H4`) reads "dd". It should be a period.
4. `,/4` reads "St." where print has "Still." (only where the cells cannot be "St.": weigh it and say what you chose).
5. `2F` inside a word, as in "befuddled", reads "before".
6. Italic `.M` reads "µ", if it is fixable without harming real "µ".

Leave the accent cell alone; the report explains why. If macOS's tables are used rather than bundled ones, a fix goes in TextMouth's own pass, never in `/System`.

### `brflayout`, branch `fix/brf-layout-and-title`

You own `BraillePageAnalyzer.swift`, `BrailleBookReader.swift`, `BrailleFileReader.swift`, and the BRF part of `FileImportService.swift`. Fix these, one commit each, each with its test:
1. Running heads leak into the text (495 pages). The braille page number sits at the left of row 1 and the print page number at the right. Take a left-hand page-number word too, and drop a head whose text repeats on 3 or more pages.
2. Roman-numeral print-page change lines (`------;IX`).
3. A centred "Chapter N" row followed directly by an indented row, with no blank row between, becomes a heading. A row made only of a rule never becomes heading text.
4. Title and author from the BRF's braille title page. Read page 1's centred rows with the book's resolved table: the title is the first row; the author is the text after a "by" row, or the second half of a "Title by Author" row. Fall back to the file name and Unknown, as today. Use only for a new import, and for this book through Replace Existing or a re-read; never overwrite a title or author the user edited.
5. Suggest the old-code table. When a BRF imported with a UEB table shows the EBAE signs often (the report's item 9: `6` joined to the next word as "to", `,N`), TextMouth should say so. A spoken or visible sentence in Book Information or at import is enough, for example "This braille looks like English Braille, American Edition. Choose its Braille Code in Book Information." Never change the table on its own. Keep the wording plain; VoiceOver must read it.

## Both workers

- Raise the reader version your change requires (`PageReaderVersions` or the braille reader's own constant), and say which books are read again at the next launch.
- You work at the same time and may need the same constant. Claim files on the board (`bbs claims`). If you both must raise one constant, `brflayout` raises it, and `brfdecode` posts a notice naming its change.
- Check each item in the code before you change it. If the report's evidence is wrong, skip the item and say why.
- Measure at the end: re-run the report's comparison of the BRF against the EPUB through your build of the helper or reader, and give the before and after counts the report gives.
- Then type-check, run one train naming your classes and areas, review your diff, rebase onto local main, run the last broad train, and report as `common.md` says.

## If the usage limit stops you

The weekly limit may run out before you finish, and the orchestrator resumes you after the reset at 07:00 EST. **Commit after every item**, so nothing is lost. Before each item, add one line to `build/orchestrator/nov13/<your name>-progress.md` in the main checkout (or, if you cannot write there, to `PROGRESS-<your name>.md` at your worktree's root, staged with `git add -f`), saying what is done and what is next.
