# Documentation pass docs20: this Mac's braille tables

You are `docs20`, a documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player.

## Setup

Your worktree starts behind local `main`. First run `git checkout -b docs/oct20 main`, then check that `git merge-base --is-ancestor e7461fe1 HEAD` succeeds.

## The task

Document team/mactables in the documentation pages, from the wording below and from the merged code. It merged twice: b5fffa42, then e7461fe1 with a second review's fixes. You may edit:
- `README.md` and `ARCHITECTURE.md`, which are indexes: change them only where an index line becomes false;
- the pages under `docs/`.

Edit no other file. Make one commit. The braille pages were written yesterday (bc5ef365): `docs/user/settings.md`, `exporting-books.md`, `what-textmouth-reads.md`, `adding-books.md`, `library-window.md`, `config-json.md`, `where-your-library-lives.md`, and `docs/architecture/state/`. Add the Mac's tables to them without repeating what they say, and correct what this merge made false. For example, the Braille tab now has three pop-ups, and its codes are no longer English only.

## How to write

- **Check each sentence against the merged code before you place it.** A quick `grep` is enough. Where the wording below and the code differ, the code wins: fix the sentence and say so in your report.
- **Match each page's style.** The user is blind and reads these pages with VoiceOver and a braille display. Write plain, exact sentences, use lists that navigate well, and quote the words a listener hears exactly, in the pages' own quotation marks.
- **Say each fact once,** on the page where it belongs, with links from the others.
- **Keep the run lean.** Read files by line range, and put several patterns in one `grep`.
- **Usage.** Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`. Stop and report if "Weekly (all models)" falls to 45% left.
- **Rules.**
  - Never push, and never merge into `main`.
  - The commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`.

## What landed

### The selector
- **The pop-ups.** A "Language" pop-up comes before "Braille code" and "Contraction", in the Braille tab and in Export's braille options (`BrailleTablePickers`).
- **Language's hints:**
  - in Settings: “The language of the braille code TextMouth reads braille files with and writes braille in.”
  - in Export: “The language of the braille code the book is written in.”
- **Defaults.** English comes first, stays built in, and stays the default: Unified English Braille, contracted.
- **Names.** Languages are named by macOS in the user's language. A language macOS cannot name takes the table's own name; for example, Munda shows as “Munda”. Codes are listed by their tables' display names, such as “French braille” or “Danish 6-dot braille (2022 standard)”.
- **Contraction values** may also be “Uncontracted (Grade 0)”, or “As the table defines” for a table that states no contraction.
- **The source sentence,** in the Braille tab only:
  - “The chosen table is built into TextMouth (liblouis 3.39.0).”
  - “The chosen table is one of this Mac's VoiceOver braille tables (liblouis 3.34.0).”
  - “This Mac no longer has the chosen table, “mac:…”; choose another.”

### This Mac's tables
- **Where they come from.** They are VoiceOver's own liblouis tables, at `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable`. They are read in place, never copied, changed, or downloaded, so the app does not grow.
- **When they are read.** Their headers are read once, at launch, in the background.
- **Which are offered:** literary tables only, six-dot, and never a table that only includes another table offered in the same language. On macOS 26.3, about 121 tables in 79 languages are usable.
- **Listed, but refused when chosen:** Greek, Hungarian, Icelandic, Serbian, and Cantonese.
- **The check.** The first time a Mac table is chosen, TextMouth checks it. The helper loads it, translates a sample of letters, digits, and typographic punctuation both ways, and measures its memory and speed. The table then runs within limits made for it, at most 64 MB and 20 seconds per MB.
- **A refusal** is spoken as “TextMouth can't use this Mac's table “<name>”: <reason>.” The reasons:
  - “it does not load in TextMouth's liblouis 3.39.0”;
  - “it writes eight-dot braille, and TextMouth uses six-dot braille only”;
  - “this Mac no longer has it”;
  - “it needs more than 64 MB of memory”;
  - “it translates too slowly, under 50 KB a second”;
  - “it could not be checked”.

  Check the exact list in `MacBrailleTableCheck.swift`.
- **A check that could not run** is spoken as “TextMouth could not check this Mac's table “…”: <why>. Choose it again to try once more.” At import or export it is “TextMouth could not check this Mac's braille table “mac:…”: <why>. Try again.”

### Stored values and books
- **The stored value.** A Mac table is stored as `mac:<file>` in the setting, in config.json's `brailleTable` (document this in `config-json.md`), and with the book.
- **The version.** A book read with a Mac table records the Mac's liblouis version.
- **A changed table.** If a macOS update changes the Mac's tables, a rebuild of the book is refused, and the book keeps its text: “This Mac's braille table “mac:…” has changed since the book was read with it, from liblouis 3.34.0 to 3.35.0, so TextMouth keeps the book's text as it was.” When no version can be read now, the sentence says the table “may have changed”. Check both in the code.
- **Book Information and Speak Info** name the language too, as in “French braille, contracted (Grade 2), in French”, or “Italian braille, in Italian”.

### Export
- **When the Settings table can't be used.** If the Braille setting's table can't be used for Export (gone, refused, or a twin), Export's options start from Unified English Braille, contracted, and say so: “TextMouth can't use the braille table chosen in Settings, “<name>”, so this export starts from Unified English Braille, contracted (Grade 2).”
- **Waiting for a check.** An export started while a just-chosen table is being checked waits for the check, with Stop offered. While the check runs, the Export button's hint is “Exports the checked items to the folder once the braille table just chosen has been checked.”
- **Eight-dot characters in the text.** Eight-dot braille characters already in a book's text are written as their six-dot part.
- **Eight-dot cells from a table.** A table that writes an ordinary character as an eight-dot cell fails that book's export, naming the character: “The braille table writes “«” as an eight-dot cell, and TextMouth writes BRF and PEF files in six-dot braille only.” For example, some tables write @ in eight-dot computer braille, so a book holding an e-mail address fails to export with them. Other books export.

### The log, architecture, and tests
- **Log tag:** `BRAILLE_MAC_TABLE_REFUSED`. Put it beside the braille helper's tags.
- **Architecture:**
  - `BrailleTableCatalog` gains the Mac's folder as a second source.
  - `MacBrailleTableCheck` does the measured check and gives each table its limits.
  - The `mac:` prefix is named in one place.
  - The helper runs a Mac table from inside the Mac's folder, never mixing the two folders.
- **Tests.** Count the areas and hosted test classes again with `python3 -I Scripts/test/run-area.py --list` and `--unassigned`, and update `docs/developer/testing.md`.

## Your report (at most 20 lines)
- The branch, and the commit's hash and subject, with the pages it changed.
- Every sentence you changed from this wording to match the code, and why.
- Anything a page said that you found false and corrected.
