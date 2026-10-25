# Documentation pass docs25: choosing a book's text encoding, and the 0.2.3 changelog (October 25, 2026)

You are `docs25`, a Sonnet documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Setup
Run `git checkout -b docs/encoding-choice integrate/encoding-choice`, then check that `git merge-base --is-ancestor 01265d9f HEAD` succeeds. `integrate/encoding-choice` is main with the `formats/encoding-choice` merge.

These are your sources, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/`, and where they disagree, the code wins:
- `encodingchoice-report.md`: the first report, with every sentence a listener hears;
- `encodingchoice-fix-report.md`: the fix round, which changed and added sentences;
- the last commit, 01265d9f: Replace Existing refuses while the same book is read again, with the sentence "TextMouth is reading “<title>” again in another encoding. Try again when that finishes."

## What to document (one commit per numbered part)
1. **The user guide.**
   - **`docs/user/library-window.md`** (Book Information): the Text Encoding pop-up.
     - Which books have it.
     - Its options, and the note on the selected one: guessed, chosen, from its byte order mark, declared in the file, the default, checking the file, not known until downloaded, can't be read.
     - The confirmation, and what happens to places, bookmarks, and an edit.
     - The sentences when it is done, and the refusals.
     - Quote every sentence exactly.
   - **`docs/user/what-textmouth-reads.md`:**
     - Where it says a guess can be missed or wrong, say how to choose another encoding.
     - A file not valid in the chosen encoding is refused, and nothing changes.
     - Name the limits a reader would meet: JIS X 0212 characters in EUC-JP are refused, as are the euro sign in Big5 and EUC-KR, and Big5-HKSCS characters.
   - **`docs/user/editing-book-text.md`:** Edit Text stops for a book that is read again in another encoding, and its edit is kept as a copy. Give the sentence.
   - **`docs/user/adding-books.md`:** add Replace Existing's new refusal to its list.
   - **`docs/user/settings.md`:** Redo Text Extraction now says why it waits while a book is read again in another encoding. Give the sentence.
   - **`docs/user/where-your-library-lives.md`:** a choice is recorded as chosen. TextMouth 0.2.2 drops that note, so a choice becomes a guess of the same encoding. The installed 0.1.1 drops both. Say it once.
2. **The architecture pages:**
   - `TextEncodingChoiceModel`;
   - `LibraryViewModel.readTextAgain` and the books being read again;
   - `TextEncodingByteGrammar`;
   - `textEncodingSource`, and the rule that a re-read's choice in the record wins over a lagging row;
   - which pages: `imports.md`, `text-caches.md`, `windows.md`, `library-index.md`, `package-records.md`, and any other page the merge's files belong to.
3. **The changelog.** In `docs/user/changelog.md`, above 0.2.2, add "## 0.2.3 (October 25, 2026)" in the page's own form: one plain sentence per change, under the page's headings. Do not change the version number: the orchestrator does that.

## How to write
- **Check each sentence against the code on your branch before you place it,** with a quick grep. The code wins: fix the sentence, and say so in your report.
- **Match each page's style.** Write plain, exact sentences. Use headings and lists that navigate well with VoiceOver and a braille display. Quote the words a listener hears exactly. Say each fact once, and link to it from the other pages.
- **Keep the run lean.** Read by line range, and put several patterns in one grep.
- **Rules:**
  - Never push, and never merge into main or `integrate/encoding-choice`.
  - Never read, copy, or write anything under ~/.TextMouth.
  - End each commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`.

## Your report (at most 15 lines)
- The branch, and each commit with the pages it changed.
- Every sentence you changed to match the code.
