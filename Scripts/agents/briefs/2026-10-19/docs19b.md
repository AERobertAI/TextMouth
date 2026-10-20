# Documentation pass docs19b: the October 20 braille merge

You are `docs19b`, a documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player.

## Setup

Your worktree starts at `origin/main`, which is far behind local `main`. First run `git checkout -b docs/oct19b main`, then check that `git merge-base --is-ancestor 3996434d HEAD` succeeds.

## The task

Document the braille merge, team/braille (merge 3996434d; FMT20, FMT21, FMT22), in the documentation pages, from the wording below and from the merged code. You may edit:
- `README.md` and `ARCHITECTURE.md`, which are indexes: change them only where an index line becomes false or a new page needs a line;
- the pages under `docs/`: `docs/user` for the person using the app, `docs/developer`, and `docs/architecture`.

Edit no other file. Make one commit. The team's notes are under "## From the braille team" in `AGENT-NOTES-2026-10-04.md`: find the line with `grep -n "^## From the" AGENT-NOTES-2026-10-04.md`, then read that section with `sed -n`. The export pages were updated on October 19 (`docs/user/exporting-books.md`, `docs/architecture/state/exports.md`); add braille to them without repeating what they say.

## How to write

- **Check each sentence against the merged code before you place it.** A quick `grep` of the label, number, or sentence is enough. Where the wording below and the code differ, the code wins: fix the sentence and say so in your report.
- **Correct what the merge made false.** For example, a page may list the kinds of XML file TextMouth reads, or say that Export's hints copy.
- **Match each page's style and level of detail.**
  - The user is blind and reads these pages with VoiceOver and a braille display; braille is the feature they care most about.
  - Write plain, exact sentences. Use headings and lists that navigate well, and nothing that relies on sight.
  - Quote the words a listener hears exactly, in the pages' own quotation marks.
- **Say each fact once.** Put it on the page where it belongs, and link to it from the others.
- **Keep the run lean.** Read files by line range, put several patterns in one `grep`, and make independent calls in one response.
- **Usage.** Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`. Stop and report if "Weekly (all models)" falls to 46% left.
- **Rules.**
  - Never push, and never merge into `main`.
  - The commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`, never a shell variable.

## What landed

### Reading braille files (FMT20, FMT21)
- **Formats.**
  - BRF and BRL files: braille ASCII, in either upper or lower case.
  - PEF files: six-dot only. Eight-dot PEF is refused.
- **Translation.** TextMouth translates them to print with liblouis, using the code chosen in Settings, Braille. A book keeps the code it was imported with, through Remove from Library Only and adding it back too.
- **Structure from the layout:**
  - a centered line, or a centered run of lines, is a level-1 heading;
  - a line at cell 5 is level 2, and a line at cell 7 is level 3;
  - paragraphs and list items are found from their indents;
  - page numbers are left out of the text, so they are never spoken.
- **Limits.** A braille file over 32 MB is refused, and so is one of more than 100,000 pages or 4,000,000 lines.
- **Not read yet:** running heads, Roman-numeral page numbers, and words divided at a line's end. Lists from other tools may read as plain paragraphs.
- **In the Finder.** `.brf`, `.brl`, and `.pef` are document types. `.pef` is also a Pentax raw photo, and the import tells the two apart by content.
- **Book Information and Speak Info.** Book Information has a row “Braille Code”, such as “Unified English Braille, contracted (Grade 2)”. Speak Info's full summary says “Braille code: …” right after the bookmarks.
- **Refusals.** Check each in the code (`BrailleFileReader.swift`, `BrailleTranslator.swift`, `ImportFailure`), and use the form the pages already use for refusals (`docs/user/adding-books.md`):
  - “Line 12 holds “é”, which is not braille ASCII.”
  - “Line 1 holds the character U+00A0, which is not braille ASCII.” Invisible characters, white space, and combining marks are named by code point.
  - “Line 12 holds the control character U+0007, which is not braille ASCII.”
  - “Line 12 holds the byte 0xE9, which is not braille ASCII.”
  - “This file could not be read as a PEF braille file. It may be damaged, or another kind of file.”
  - “This file is eight-dot braille, which TextMouth does not read.”
  - “TextMouth has no braille table named “en-xx.ctb”.”
  - “TextMouth stopped the braille translation because …”, followed by the watchdog's reason.
  - “TextMouth could not translate this braille.”
  - “This file has more than 100,000 braille pages, the most TextMouth reads.”
  - “This file has more than 4,000,000 lines of braille, the most TextMouth reads.”
  - The 32 MB refusal. Find its words in the code.
  - The XML refusal changed to “This XML file is not a DTBook book, a Word 2003 XML document, or a PEF braille file, the kinds of XML file TextMouth reads.”

### The Braille tab in Settings (FMT21)
- **“Braille code”:** values “Unified English Braille” and “English Braille, American Edition”. Its hint is “The braille code TextMouth reads braille files with and writes braille in.” Check the hint in the code: the tab and Export's options now share one view, `BrailleTablePickers`.
- **“Contraction”:** values “Uncontracted (Grade 1)” and “Contracted (Grade 2)”. Its hint is “Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells.”
- **The default** is Unified English Braille, contracted.
- **The caption:** “TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with.”
- **With no tables in the bundle:** “TextMouth found no braille tables in its bundle.”
- **config.json** mirrors the setting as `brailleTable`. Document it in `docs/user/config-json.md` in that page's form.
- **The four bundled tables:** Unified English uncontracted (en-ueb-g1.ctb) and contracted (en-ueb-g2.ctb) braille, and English uncontracted (en-us-g1.ctb) and contracted (en_US.tbl) braille as used in the U.S.

### Writing braille (FMT22)
- **Convert to** gains “BRF” and “PEF”:
  - BRF's hint: “Braille Ready Format: pages of braille ASCII, for braille displays and embossers.”
  - PEF's hint: “Portable Embosser Format: pages of Unicode braille in XML, for embossers.”
- **Options under the picker,** while BRF or PEF is chosen, starting from the Braille setting at 40 cells by 25 lines:
  - “Braille code”, hint “The braille code the book is written in.”;
  - “Contraction”, hint “Whether that code's braille is contracted.”;
  - “Cells per line”, value such as “40 cells”, hint “How many braille cells each line holds, from 18 to 80.”;
  - “Lines per page”, value such as “25 lines”, hint “How many lines each braille page holds, from 4 to 50.”;
  - a “Braille page numbers” checkbox, hint “Whether each page's last line carries its braille page number.”;
  - “Line ends”, for BRF only, values “CR LF” and “LF”, hint “CR LF suits most braille displays and embossers.”

  The options are disabled while an export runs.
- **The layout,** after BANA's Braille Formats:
  - headings 1 and 2 centered, heading 3 at cell 5, and headings 4 to 6 at cell 7;
  - paragraphs starting in cell 3 and running over in cell 1;
  - list items starting in cell 1 and running over in cell 3, with a blank line before and after a list;
  - a form feed between pages;
  - the braille page number at the right of a page's last line.
- **Characters a table lacks,** such as Chinese, Cyrillic, and emoji, are written in liblouis's escape notation and read back as it. Both files hold six-dot cells only.
- **A word longer than a line** is cut, after a hyphen or slash where it can be, never inside a number, and with no hyphen or continuation indicator yet.
- **File names:** “<title> - Text.brf” and “<title> - Text.pef”.
- **The Export dialog's hints changed:**
  - Export: “Exports the checked items to the folder.”
  - Stop: “Stops the export. The file being made is not kept.”

### Older builds, licences, and the log
- **An older TextMouth can't open the library.** A TextMouth built before this merge cannot open a library that holds a braille book (`BookFormat.braille` is new). It keeps the library's file and writes nothing, so nothing is lost. Say this where the pages describe older versions, as the October 18 pass did for the textutil formats.
- **Licences.** liblouis's and LAME's licence files now ship inside the app, in `Contents/Resources/Licenses/liblouis` and `Licenses/LAME`.
- **Debug log tags:** `BRAILLE_HELPER_FAILED` and `BRAILLE_HELPER_KILLED`. Put them beside the other process tags.

### Developer pages (docs/developer)
- **`third-party-code.md`.** Add a liblouis entry like LAME's:
  - liblouis 3.39.0, LGPL 2.1 or later, in `Vendor/liblouis`;
  - the tarball's SHA-256, in `project.yml`;
  - `config.h` and `include/liblouis.h` as TextMouth's own files;
  - the four tables and the 13 files they include;
  - nothing from liblouis's `tools/`, which is GPL 3;
  - it runs only in the TextMouthBraille helper;
  - how to update it, from `project.yml`'s comment.

  Correct the page's "one library by other authors", and say where the licence files ship.
- **`building.md`.** The TextMouthBraille helper target. Header maps are off (`USE_HEADERMAP: NO`) for LAME, liblouis, and the helper, because Xcode's header map handed liblouis LAME's `config.h`. XcodeGen 2.45.3 orders the three copy-files phases differently on each run, which changes nothing in the build. Place each fact only where the page covers that subject.
- **`testing.md`.** The new `braille` area. Count the areas and the hosted test classes again: `python3 -I Scripts/test/run-area.py --list` and `--unassigned`, which build nothing. Update the October 19 counts.

### Architecture (docs/architecture)
- **Reading:** `BrailleFileReader`, then `BraillePageAnalyzer`, then `BrailleTranslator` (the helper, through `WatchedProcess`), then `BrailleBookReader` into the Markdown cache, with the table from `Book.brailleTable`.
- **Writing:** the export walker's `ExportDocument`, then the BRF and PEF writers (`BrailleExportWriters`, through `TextExportWriter`), then `BrailleDocumentWriter`, `BrailleTranslator`, `BrailleLayout`, and `BrailleFileWriter`.
- **Tables:** `BrailleTableCatalog` reads the tables' own metadata. `BraillePreferences` keeps the setting, mirrored in config.json. `BrailleTablePickers` is the pop-up view the Braille tab and Export's options share.
- **The helper:** `TextMouthBraille/main.c`, with three modes (check, forward, and back). It accepts only the catalog's tables and loads them from inside their folder.
- Find the pages that own importing, exporting, and settings (`ARCHITECTURE.md` lists them), and add only what a developer needs to find their way.

## Your report (at most 25 lines)
- The branch, and the commit's hash and subject, with the pages it changed.
- Every sentence you changed from this wording to match the code, and why.
- Any wording you could not place.
- Anything a page said that you found false and corrected.
