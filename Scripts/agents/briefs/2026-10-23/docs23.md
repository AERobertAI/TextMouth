# Documentation pass docs23: transcripts, stability, the older-build warning, and the 0.2.1 changelog (October 23, 2026)

You are `docs23`, a Sonnet documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Setup
Run `git checkout -b docs/oct23 main`, then check that `git merge-base --is-ancestor 8aa0c690 HEAD` succeeds.

## What to document (one commit per numbered part)
1. **The transcripts merge** (fec4de73). The lead's report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/transcripts-lead-report.md`, and its "For the documentation pass" section has wording. The fix agent's report, `transcripts-fix-report.md` beside it, changed some sentences: the code wins.
   - **`docs/user/transcribing.md`:**
     - Retranscribe Audio…, and what the sheet says it replaces;
     - a feed episode's transcript can now be edited and cleaned up, with its note;
     - the iCloud checks before retranscribing.
   - **`docs/user/editing-book-text.md`:** the refusals of a renamed heading and of words added to a chapter with no speech.
   - **`docs/user/reader-windows.md`:** Search in Book (Command-F) on a transcribed audiobook, its results' words and times, Return on a result, Go Back (Command-[), and the sentences when there is nothing to search.
   - **`docs/user/exporting-books.md`:** Text as Markdown and the Transcript's Markdown are written afresh, with backslashes only where Markdown needs them and without chapter-marker lines.
   - **The architecture pages,** from the report's ARCHITECTURE list.
2. **The stability merge** (8aa0c690). The report is `stable020-lead-report.md` beside the others; use its "Documentation wording" and "What a listener hears".
   - **`docs/user/adding-books.md`:** the duplicate question's new words.
   - **`docs/user/settings.md`:** Storage's sentence about books a newer TextMouth wrote.
   - **The first launch:** say what it does, on the page that describes it (`where-your-library-lives.md`): open readers get their new text with pages, and EPUB page breaks keep their words.
   - **The architecture pages,** from its list.
3. **V01, saying truly what going back to 0.1.1 does.** Read the TODO's V01 item, in the main checkout: `grep -n "V01 —" /Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`. Its facts are also in `humanQuestions/2026-10-23.md` there.
   - 0.1.1 refuses a library holding a book in any of eight formats: braille, rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archives, and SSML.
   - It still writes book records, which lose 0.2.0's records of edits and pages.
   - Never choose Rebuild Library Index in 0.1.1.

   Correct `docs/user/changelog.md`'s 0.2.0 caution (it names only braille), `where-your-library-lives.md`, and `cloud-library.md` (check its line 38).
4. **The 0.2.1 changelog section.** In `docs/user/changelog.md`, above 0.2.0, add "## 0.2.1 (October 23, 2026)" in the page's own form. Use one plain sentence per change, grouped under the page's headings:
   - Retranscribe Audio…;
   - editing and cleaning up a feed episode's transcript;
   - Search in Book for transcripts;
   - Markdown exports without needless backslashes;
   - the transcription fixes;
   - resume after a quick Pause;
   - precise MP3 seeking;
   - Play during a move;
   - EPUBs that name files in another case;
   - Word 97-2003 files with fields;
   - the duplicate question;
   - 0.2.x opening a library a later version wrote.

   Do not change the version number: the orchestrator does that.

## How to write
- **Check each sentence against the merged code before you place it,** with a quick grep. The code wins: fix the sentence and say so in your report.
- **Match each page's style.** Plain, exact sentences; headings and lists that navigate well with VoiceOver and a braille display; the words a listener hears quoted exactly. Say each fact once, and link to it from the other pages.
- **Keep the run lean.** Read by line range, and put several patterns in one grep.
- **Usage.** The user set tonight's line at 5% of the week left, so the usage rule's "low" status does not stop you. Stop only if "Weekly (all models)" falls to 6% left.
- **Rules.**
  - Never push, and never merge into main.
  - Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Markdown only.
  - Use literal paths in every `rm`.

## Your report (at most 20 lines)
- The branch, and each commit with the pages it changed.
- Every sentence you changed to match the code.
- Anything false that you corrected.
