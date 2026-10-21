# Documentation pass docs21: pages, braille emphasis, and the reader-load race (October 21, 2026)

You are `docs21`, a Sonnet documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Setup
Run `git checkout -b docs/oct21 main`, then check that `git merge-base --is-ancestor 597bea47 HEAD` succeeds.

## The task
Document three merges in the documentation pages, from the merged code and the notes in `AGENT-NOTES-2026-10-04.md`:
- **"## From the pages team"** (team/pages, 77e798a0);
- **"## From brailleemphasis"**, if present, or else the TODO's emphasis entry (b4ca969e);
- **the reader-load race** (825a3f23), whose TODO entry is in the main checkout's `TODO-2026-09-04.md`: `grep -n "A book moved while it opens" TODO-2026-09-04.md`.

Find each notes section with `grep -n "^## From the" AGENT-NOTES-2026-10-04.md`, then read it with `sed -n`. Make one commit.

You may edit only:
- `README.md` and `ARCHITECTURE.md`, which are indexes: change an index line only where it becomes false;
- the pages under `docs/`.

## What to write
1. **Pages.**
   - **The user's pages:**
     - `reader-windows.md`: the Page navigation unit; Next Page (Option-Command-Right Arrow), Previous Page (Option-Command-Left Arrow), and Go to Page… (Option-Command-G); the status row's "Page 12 of 300" button; and Where Am I?'s page.
     - `settings.md`: the Playback tab's "Pages" group and its two settings.
     - `editing-book-text.md`: what `<!-- page: … -->` lines are, and that deleting one deletes that page.
     - `what-textmouth-reads.md`: which formats have pages. A DOCX that Word never laid out, or a DOC, shows fewer pages than Word, and textutil loses `\pagebb` and `\sect`.
     - `config-json.md`: `showsPageInReader` and `saysPageInWhereAmI`.
   - **Existing books** gain pages only through Redo Text Extraction for now, because the launch re-read is switched off until PG16. Say it plainly, on the page where books' text is re-read.
   - **B12.** A finished Edit Text change is now kept by automatic re-reads, and Redo Text Extraction keeps a copy of the replaced text as `content.md.edited-<time>` in the book's package.
   - **The architecture pages:** content.md's markers, `MarkdownPageMarker` and `MarkdownMarkerWriter`, `BookPages`, `PagePosition`, `ReadingTextCache` layout 2, `includesPages`, and `Book.editedText` and `Book.pageReaderVersion`.
   - **Quote the words a listener hears exactly,** from the pages notes or the code: the announcements, the Go to Page field's label, hint, and refusals, the settings' hints, and Where Am I?'s sentence.
2. **Braille emphasis.** On the braille pages (`what-textmouth-reads.md`, `exporting-books.md`, and the architecture pages):
   - reading UEB braille keeps its emphasis as italic and bold in the book's text, never spoken;
   - exporting writes italic and bold as UEB emphasis;
   - EBAE, and most of this Mac's tables, write and read plain braille, since liblouis cannot read their emphasis back;
   - the helper's protocol 2 is defined in `TextMouthBraille/include/TextMouthBrailleProtocol.h`.
3. **The reader-load race.** Add only what a developer needs: a sentence on the architecture page that owns the reader's load or the library's moves, naming `LibraryBookUpdates.isPackageMoving` and `beginReadingForLoad()`. A user never sees the fix, so the user's pages need nothing.
4. **The testing page.** Recount the areas and hosted classes with `python3 -I Scripts/test/run-area.py --list` and `--unassigned`, which build nothing, and update `docs/developer/testing.md`.

## How to write
- **Check each sentence against the merged code before you place it,** with a quick grep. Where wording and code differ, the code wins: fix the sentence and say so in your report.
- **Match each page's style.** Write plain, exact sentences, use lists that navigate well with VoiceOver and a braille display, and quote the words a listener hears exactly. Say each fact once, and link to it from the other pages.
- **Keep the run lean.** Read by line range, and put several patterns in one grep.
- **Usage.** Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`. Stop and report if "Weekly (all models)" falls to 30% left.
- **Rules.**
  - Never push, and never merge into main.
  - The commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Markdown only.
  - Use literal paths in every `rm`.

## Your report (at most 20 lines)
- The branch, and the commit's hash and subject, with the pages it changed.
- Every sentence you changed to match the code.
- Anything false that you corrected.
