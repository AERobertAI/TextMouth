# Documentation pass docs19: the October 19 export and braille merges

You are `docs19`, a documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player.

## Setup

Your worktree starts at `origin/main`, which is far behind local `main`. First run `git checkout -b docs/oct19 main`, then check that `git merge-base --is-ancestor 39df3467 HEAD` succeeds.

## The task

Document the merges of October 19 in the documentation pages, from the wording their teams left and from the merged code. You may edit:
- `README.md` and `ARCHITECTURE.md`, which are indexes. Change them only where an index line becomes false or a new page needs a line. For example, README's line for exporting says "what Export copies out of the library", and Export now converts too.
- The pages under `docs/`: `docs/user` for the person using the app, `docs/developer`, and `docs/architecture`.

Edit no other file. Make one commit per documented merge:
1. **Now: team/export** (merge 0db62a38). Its notes are under "## From the export team" in `AGENT-NOTES-2026-10-04.md`. Find the line with `grep -n "^## From the" AGENT-NOTES-2026-10-04.md`, then read the section with `sed -n`. Its wording is below.
2. **Later: team/braille.** It has not merged yet. When it has, the orchestrator sends you a message with its merge hash and wording. Until then, write nothing about braille.

After commit 1, send your report (the form is at the end) and stop.

## How to write

- **Check each sentence against the merged code before you place it.** A quick `grep` of the label, number, or sentence is enough. Where the wording below and the code differ, the code wins: fix the sentence and say so in your report.
- **Correct what the merge made false.** For example, a page may say that Export only copies.
- **Match each page's style and level of detail.**
  - The user is blind and reads these pages with VoiceOver and a braille display.
  - Write plain, exact sentences. Use headings and lists that navigate well, and nothing that relies on sight.
  - Quote the words a listener hears exactly, in the pages' own quotation marks (“ ”).
- **Say each fact once.** Put it on the page where it belongs, and link to it from the others.
- **Keep the run lean.** Read files by line range, put several patterns in one `grep`, and make independent calls in one response.
- **Usage.** Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`; "Weekly (Fable)" does not apply. Stop and report if "Weekly (all models)" falls to 56% left.
- **Rules.**
  - Never push, and never merge into `main`.
  - Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`, never a shell variable.

## Commit 1: team/export (FMT18, FMT19)

### What landed

**Convert to.** The Export dialog's "Text as Markdown" checkbox gains a Convert to picker beside it, shown only while that box is checked. Check the details in `TextMouth/Views/Export/BookExportSheet.swift`, `TextMouth/ViewModels/BookExportModel.swift`, and `TextMouth/Models/BookExportWording.swift`.
- **The choices:** Markdown, HTML, RTF, and “Word 97-2003 (.doc)”.
  - Every dialog starts on Markdown, so an export made as before gives the same file, under the same name.
  - Audiobooks have no picker.
- **The picker's hints:**
  - Markdown: “The book's text as Markdown, the file TextMouth reads it from, as it is.”
  - HTML: “A web page of the book's text, with a contents list linking each heading.”
  - RTF: “Rich text, with each heading at its outline level, for Word, Pages, and TextEdit.”
  - Word: “Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them.”
- **The checkbox while a writer is chosen.** Its name follows the picker: “Text as HTML”, or “Text as HTML, 2 books” for several books. It gives no size, since a converted file's size is known only once it is written. With Markdown chosen, it keeps its size, as before. Its hint is “The book's text as HTML, made from the Markdown TextMouth reads it from.”, with RTF or Word 97-2003 (.doc) in place of HTML.
- **File names:** each book gets its own file, such as “<title> - Text.html”, “.rtf”, or “.doc”, numbered when the name is in use, as Markdown's are.
- **Conversion and its failures.** Each book is converted off the main thread, one at a time, under the dialog's progress bar and Stop.
  - A book that cannot be converted is named in the end-of-export sentence, with why, and the other books still export.
  - The Word writer's failure is “Couldn't export <file name>: The book's text could not be made into a Word 97-2003 document.” Check the form in `WordDocExportWriter.failureSentence` and the dialog's failure sentence.

**What each format holds.** The text comes from the book's content.md, the Markdown TextMouth reads it from. Markdown stays the base, and every format is written from it.
- **What every format leaves out:**
  - content.md's chapter markers, its navigation annotations, and raw HTML are left out;
  - a picture becomes its alternative text.
- **Headings:**
  - A chapter with no heading of its own gets its title as a level-1 heading, as the reader's heading list shows it.
  - The book's title becomes a level-1 heading only when the text has none.
- **HTML:**
  - It is a web page (XHTML) with the book's title and its language when the book has one.
  - It has a contents list, a navigation landmark VoiceOver names “Contents”, linking each heading.
  - Only http, https, and mailto addresses become links; any other link is plain text.
- **RTF:**
  - Headings are bold and larger (22 down to 13 point), and carry outline levels, so TextMouth reads them back as headings at the same levels.
  - Lists are paragraphs that start with a bullet or a number and a tab.
  - A table wider than 63 columns becomes tab-separated paragraphs.
- **Word 97-2003 (.doc):**
  - Apple's writer makes it from TextMouth's RTF. Its headings are larger and bold, but plain text, so Word's navigation pane does not list them.
  - Six rare characters are lost: the bidirectional embedding controls U+202A to U+202E, and U+FFFD, which becomes “?”. The RTF keeps them.
- **Not yet checked:** whether Word's navigation pane lists the RTF's headings. No real Word, Pages, or LibreOffice has opened an export yet. Say so only where the pages say what is known to work, if they do.

**File safety, for every kind, not only conversions.** Every exported file, whether copied, plain text, or converted, is now made in a scratch folder on the target's own volume, then moved into the chosen folder only once it is whole, and never over a file that is there. An export therefore never replaces or removes a file in the chosen folder, and Stop leaves no half-written file. The exported page already says that a name in use gets a number; keep that, and add only what is new.

### Architecture (docs/architecture)

`ARCHITECTURE.md` lists the page for exports (`docs/architecture/state/exports.md`); `docs/architecture/parts-of-the-app.md` may need a line. The team's wording:

“`TextMouth/Services/Export/` holds text export (FMT18, FMT19):
- `ExportDocument`, the model every writer reads;
- `ExportDocumentWalker`, the one swift-markdown walk of content.md, since Markdown stays the base;
- `TextExportWriter`, the writer protocol, with the `TextExportWriters.all` registry, the `TextExportConversion` erasure, and the dialog's options state;
- `HTMLExportWriter` with `XMLEscaping`, `RTFExportWriter`, and `WordDocExportWriter`, which is Apple's `.docFormat` from TextMouth's RTF.

`BookExportService` plans a converted kind's files as `.converted` sources, and writes every file through a scratch file that is moved into place with an exclusive rename (`renamex_np` with `RENAME_EXCL`), or an exclusive copy across volumes. `BookExportConversion` is the job runner's conversion: text now, audio later. `BookExportModel` keeps the Convert to choice and each writer's options, and `BookExportSheet` draws the picker.”

Add that a new writer is one new file plus one line in `TextExportWriters.all`, and that `Scripts/agents/briefs/2026-10-19/export/interface-for-braille.md` describes the interface.

### Developer pages (docs/developer)

- `Scripts/test/areas.conf` has a new area, `export` (line 403), holding the export classes. Count the areas and the hosted test classes again: `python3 -I Scripts/test/run-area.py --list` and `--unassigned`, which builds nothing. Update the October 18 counts in `docs/developer/testing.md`, around line 46.
- The new test classes are `ExportDocumentWalkerTests`, `HTMLExportWriterTests`, `RTFExportWriterTests`, `BookExportConversionTests`, and `BookExportConvertToTests`. Name them only where the page lists classes by topic.

### The team's README sentence (for README-level wording, if an index line needs it)

“Export can now convert a text book's text. While “Text as Markdown” is checked, a Convert to menu beside it chooses Markdown (the default, as before), HTML (a web page with a contents list linking each heading), RTF (each heading at its outline level, for Word, Pages, and TextEdit), or Word 97-2003 (.doc), whose headings are plain text, so Word's navigation pane does not list them. Each book gets its own file, such as “<title> - Text.html”. An export never replaces or removes a file in the folder, and Stop leaves no half-written file.”

## Your report (at most 25 lines)

- The branch, and each commit's hash and subject, with the pages it changed.
- Every sentence you changed from this wording to match the code, and why.
- Any wording you could not place.
- Anything a page said that you found false and corrected.
