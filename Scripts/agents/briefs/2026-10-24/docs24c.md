# Documentation pass docs24c: text files in other encodings (FMT16), October 24, 2026

You are `docs24c`, a Sonnet documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Setup
Run `git checkout -b docs/fmt16 integrate/fmt16`, then check that `git merge-base --is-ancestor 62575681 HEAD` succeeds. `integrate/fmt16` is main (0.2.2) with the `formats/encodings` merge (1cf19935).

These are your sources, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/`, and where they disagree, the code wins:
- `fmt16-report.md`: the first report and its first fix round, with the wording;
- `fmt16-fix2-report.md`: the second fix round;
- `verify-fmt16-2-report.md`: the reviewer's final check, with the limits that remain;
- `merge-fmt16.txt`: the merge's summary.

## What to document (one commit per numbered part)
1. **The user guide.**
   - **`docs/user/what-textmouth-reads.md`:** say which encodings TextMouth guesses, and when.
     - A plain text, Markdown, or HTML file that is neither UTF-8 nor UTF-16, and names no encoding, is no longer always read as Windows-1252.
     - At its import, TextMouth guesses among the encodings its catalog names (`TextEncodingCatalog.swift`). It guesses only when the Windows-1252 reading shows it is wrong and the whole file reads back byte for byte, and the same bytes always give the same guess.
     - The limits a reader would meet: short texts, and some languages, are left as Windows-1252. The reports name Hungarian, Croatian, Slovenian, Latvian, short Mac Roman sentences, one-line Cyrillic notes, and identifier-only files with accented capitals.
     - Books already in the library keep their text.
   - **The page that describes Book Information and Speak Info:** the row "Text Encoding, Windows-1251 (Cyrillic), guessed", and Speak Info's sentence "Text encoding: Windows-1251 (Cyrillic), guessed." Check both against `LibraryInfoWording.swift` and the tests that pin them.
   - **`docs/user/where-your-library-lives.md`:** the library row and the book's record (bookInfo.json) keep the encoding. An older TextMouth drops it when it saves them, and that book's text may then read as Windows-1252 the next time it is rebuilt. Say it once, plainly, and link to it from the changelog.
2. **The architecture pages:**
   - `docs/architecture/state/imports.md`: `TextEncodingGuesser`, `TextPlausibility`, `TextEncodingCatalog`, `TextFileDecoder`'s encoding policy, `Book.textEncoding` and `recordedTextEncoding()`, and the `TEXT_ENCODING_GUESS` log line.
   - `docs/architecture/state/text-caches.md`: rebuilds read with the recorded encoding (`MarkdownCacheService.encodingPolicy(of:)`).
   - Any other page the merge's files belong to.
3. **The changelog.** Today's version is still 0.2.2, so add to the 0.2.2 section of `docs/user/changelog.md`, under the page's own headings: one plain sentence for the guess, one for Book Information and Speak Info, and the caution about an older TextMouth. Do not change the version number.

## How to write
- **Check each sentence against the code on your branch before you place it,** with a quick grep. The code wins: fix the sentence, and say so in your report.
- **Match each page's style.** Write plain, exact sentences. Use headings and lists that navigate well with VoiceOver and a braille display. Quote the words a listener hears exactly. Say each fact once, and link to it from the other pages.
- **Keep the run lean.** Read by line range, and put several patterns in one grep.
- **Rules:**
  - Never push, and never merge into main or `integrate/fmt16`.
  - Never read, copy, or write anything under ~/.TextMouth.
  - End each commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.
  - Use literal paths in every `rm`.

## Your report (at most 15 lines)
- The branch, and each commit with the pages it changed.
- Every sentence you changed to match the code.
