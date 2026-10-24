# Documentation pass docs24: pages, braille reading, Replace Existing, and the 0.2.2 changelog (October 24, 2026)

You are `docs24`, a Sonnet documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Setup
Run `git checkout -b docs/oct24 integrate/oct24`, then check that `git merge-base --is-ancestor b1077e0c HEAD` succeeds. `integrate/oct24` holds four merges that are not on main yet. Reviews of them are still running, so a sentence may still change: the code on your branch wins, and the orchestrator will message you about any change that lands later.

The agents' reports are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/`: `pagespolish-report.md`, `pg12-report.md`, `braillereading-report.md`, and `st04-report.md`.

## What to document (one commit per numbered part)
1. **The pages follow-ups** (merge 7d0e0794, `pagespolish-report.md`).
   - **`docs/user/reader-windows.md`:**
     - Go to Page's "Jumped to page N." names the page the status row shows;
     - Return on an unchanged label that another page also carries goes to that label's next page, and wraps after the last;
     - headings no longer carry a page-break number ("Part 9Two" reads "Part Two");
     - page commands do nothing while a book is still loading;
     - the playback bar's unit pickers leave Page out for a book without pages, while Settings' pickers keep it.
   - **`docs/architecture/state/reader.md`,** and any other architecture page that the report's changed files belong to.
2. **Braille pages and form feeds** (merge 1aab977d, `pg12-report.md`). pg12 already updated the user guide in its commit 5eed1656: read what it wrote first, and add only what is missing.
   - **The user guide:** a BRF or PEF page is the braille page, labelled by its braille page number read as print (for example "p1"). A BRL has no pages. Plain text gets a page at each form feed between words.
   - **The first launch, on the page that describes it** (`where-your-library-lives.md`, and wherever it is described): braille, plain text, EPUB, and HTML books are read again once. A book whose new reading differs from its text keeps a copy of its old text beside it (the `content.md.edited-` copies that page already describes). Say it once, and link to it from other pages.
   - **The architecture pages:** the braille page analyzer, `BrailleBookReader+Pages.swift`, and the two new `PageReaderVersions` lines (V07).
3. **Braille emphasis reading** (merge c59f1540, `braillereading-report.md`).
   - **`docs/user/what-textmouth-reads.md` and `docs/user/exporting-books.md`:**
     - EBAE braille now carries italic and bold both ways, and no longer reads stray periods ("a .cat");
     - contracted UEB no longer misreads a word before an emphasis end sign ("people" no longer reads "p");
     - correct every sentence that still says EBAE is plain, or that contracted UEB misreads;
     - give the known limits only where a reader would meet them.
   - **The architecture page for the braille helper.**
4. **Replace Existing keeps the old copy's state** (merge 45ee806e, `st04-report.md`, whose "New sentences a listener hears" gives the exact words).
   - **`docs/user/adding-books.md`:**
     - the duplicate question's new sentences, for a text book and for an audiobook;
     - Replace Existing's hint;
     - the Trash sentence chosen by the Trash setting;
     - the refusals, after which the question stays open;
     - the failure sentence;
     - the Edit Text sentence.
   - **`docs/architecture/state/imports.md`:** the paragraph that says "These are the words only", and the new `DuplicateReplacement.swift`.
5. **The 0.2.2 changelog section.** In `docs/user/changelog.md`, above 0.2.1, add "## 0.2.2 (October 24, 2026)" in the page's own form: one plain sentence per change, grouped under the page's headings, covering parts 1 to 4. Leave the 0.2.1 and older sections as they are: they describe their own releases. Do not change the version number: the orchestrator does that. A later merge (text files in other encodings) will add its own lines.

## How to write
- **Check each sentence against the code on your branch before you place it,** with a quick grep. The code wins: fix the sentence, and say so in your report.
- **Match each page's style.** Write plain, exact sentences. Use headings and lists that navigate well with VoiceOver and a braille display. Quote the words a listener hears exactly. Say each fact once, and link to it from the other pages.
- **Keep the run lean.** Read by line range, and put several patterns in one grep.
- **Rules:**
  - Never push, and never merge into main or `integrate/oct24`.
  - End each commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`.
  - The weekly usage rule's "low" and "critical" statuses do not stop you tonight: the user asked to use the week's last usage before it resets at 08:00. If the API refuses, stop; you are resumed after the reset.

## Your report (at most 20 lines)
- The branch, and each commit with the pages it changed.
- Every sentence you changed to match the code.
- Anything false that you corrected.
