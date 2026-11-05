# TextMouth's own readers: the pattern (November 4, 2026)

On November 4, 2026 the user wrote: "I think small Text Mouth readers for .doc /odt etc might be good for both so formatting extraction is under our control, same for kfx", and then: "go ahead and start agents on the new parsers / readers for .doc / .rtf .mobi or integrating some for Text Mouth."

This file is the pattern every reader agent follows tonight. It stands in for AGENTS.md: do not read AGENTS.md, README.md, ARCHITECTURE.md, the TODO, or AGENT-NOTES. Read `FORMAT-LIBRARIES-RESEARCH-2026-11-04.md` (repository root) only in your format's section.

## The project

- **Repository:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`. TextMouth is a native macOS text-to-speech and audiobook player for a VoiceOver and braille user. Since November 4 it also has an iOS 26 target compiled from the same sources (`TextMouthiOS`), which iOS's lack of helper programs keeps from reading these formats.
- **Your base:** the branch `core/own-readers`, from main at version 0.2.6, whose full suite is **9337 tests, 75 skipped, 0 failures**. The user installs main, so main must stay stable.
- **The reading text.** Every book becomes Markdown, its content.md, with headings, page markers (`<!-- page: 12 -->`), and heading annotations. Most formats get there as HTML through the shared `HTMLToMarkdownConverter` (TextMouth/Parsers/HTMLToMarkdownConverter.swift), which already handles headings, paragraphs, emphasis, lists, tables, and page-break elements. **Your reader produces HTML for it.** Do not write Markdown yourself, and do not build a second converter.

## What every reader must be

- **Portable Swift**, compiled into both apps: Foundation and the packages TextMouth already has (SwiftSoup, ZIPFoundation). No AppKit, no UIKit, no `Process`, no new dependency, no C.
- **Written from the format's specification**, with the permissively licensed implementations your brief names read as maps of the algorithm.
  - Never copy their code.
  - If a function of yours ends up close to one of theirs, say so in its comment and in your report, so the orchestrator can add the licence notice.
  - GPL and LGPL code (calibre, KindleUnpack, libmobi, antiword, catdoc, wvWare, LibreOffice) is not to be read at all.
- **Safe on hostile files.** A book's file is untrusted input. The October 14 incident (Apple's Ogg decoder, run inside the app, locked the Mac at 34 GB) is the reason TextMouth is strict here.
  - Every offset, length, count, and index read from the file is checked against the data before use. A sector, record, or piece out of range ends the read with an error.
  - Caps on everything a file can make large:
    - the bytes read: use `DocumentByteLimit` where the textutil reader does;
    - the records or sectors walked;
    - a chain's length, detecting cycles;
    - the decompressed size, held to its declared size and an absolute cap;
    - the HTML written;
    - the nesting depth.
  - No recursion on a depth the file controls: keep your own stack.
  - No `fatalError`, no `precondition`, no force unwrap, no unchecked subscript on file data, no `try!`.
  - A file the reader cannot read throws a typed error whose sentence a listener can act on. Look for the wording TextMouth already uses for the same case, such as `PasswordProtectedDocument` and the refusals in `FileImportError`, and reuse it.
- **Tested hard.** Beside the real samples (`TestData/format-samples/<format>/`, listed in `TestData/format-samples/samples.tsv`), write tests that build hostile files in code, and require each to throw cleanly in well under a second:
  - truncated at many lengths;
  - every offset field pointed past the end;
  - counts set to the maximum;
  - cycles;
  - deep nesting;
  - random byte flips of a sample (a fixed seed).

  Tests copy a sample into their own folder before reading it (`copyOfFormatSample`, `formatSampleURL` in `TextMouthProductionTests/FormatSampleFixtures.swift`). A new synthetic sample file needs a line in samples.tsv, made by a script you add under `Scripts/`, with the licence CC0-1.0.
- **Swift 6, complete concurrency checking.** No `@unchecked Sendable` and no `nonisolated(unsafe)` (`UncheckedConcurrencyPolicyTests` pins their counts).
- **Commented and DRY.** A comment on every function and every non-obvious block, saying what and why.
  - Reuse what exists: `DocumentByteLimit`, `TextFileDecoder` (text in a code page), `MarkdownPageMarker`'s and `TextutilPageBreaks`' constants, `ParserUtilities`, the EPUB reader's ways with a table of contents.
  - Read a file by line range, and `grep -rn` before you write a helper that may exist.

## The HTML your reader writes

For `.doc` and RTF, the contract is the comment on `OwnDocumentReaders` (TextMouth/Parsers/OwnDocumentReaders.swift): read it first.
- One HTML document. Its head has `<title>` and `<meta name="author" content="…">` when the file names them.
- Its body has:
  - `h1` to `h6` for headings (levels 7 to 9 are `h6`);
  - `p` for paragraphs;
  - `em` and `strong` for emphasis;
  - `ul`, `ol`, and `li` for lists;
  - `table`, `tr`, and `td` for tables;
  - every text escaped.
- **Pages,** when `includesPages` is true: empty `<span role="doc-pagebreak" aria-label="N"></span>` elements, exactly as `TextutilPageBreaks.insertPageBreaks(fromPlainText:into:)` writes textutil's, so a format's pages stay the same when its reader changes:
  - page 1 at the start of the body of any document holding a letter or digit;
  - each later page, numbered on from 2, right before its first letter or digit;
  - none after a break with no letter or digit after it;
  - no pages at all past `TextutilPageBreaks.maximumPages`.

The MOBI reader writes its chapters' HTML the same way, with no pages.

## The Mac and iOS

- `OwnDocumentReaders.html(of:as:includesPages:)` is asked, inside `TextutilDocumentReader`, after a file's bytes have shown its format and a password-protected file has been refused. Your reader's case returns its HTML there behind a switch of its own:

      /// Whether this platform reads the format with this reader: iOS,
      /// which has no textutil, always; the Mac once the reader has been
      /// checked against textutil's reading of the same files.
      static var isOn: Bool {
          #if os(macOS)
          false
          #else
          true
          #endif
      }

- **The Mac keeps textutil** for your format until that check is done. So:
  - your tests call your reader directly;
  - a comparison test runs both readers on every sample of your format on the Mac (textutil runs in tests) and requires the same words in the same order (whitespace, emphasis markers, and page markers aside), listing every difference in its failure message;
  - your report gives the comparison's results, heading by heading.
- **The switch commit.** If, and only if, the comparison finds the same words in every sample and at least textutil's headings, make one last commit, separate from everything else:
  - it turns `isOn` on for the Mac;
  - it gives your format a page reader line of its own in `PageReaderVersions` (TextMouth/Models/PageReaderVersions.swift; read its comments), so the user's existing books of the format are read again once;
  - it updates the tests that pin those versions (`PagesUpgradeTests`, `OnDiskContractTests`).

  The orchestrator and the reviewer decide whether that commit merges.
- `make typecheck-ios` must stay at 0 errors and 0 warnings, and `make typecheck-mac` too.

## Builds and checks

Nobody runs xcodebuild. The Mac has 8 GB of memory, and parallel builds froze it on October 31.
- **Type-checks** take a machine-wide lock (`Scripts/agents/heavy_lock.py`) that the build train shares; a check waits its turn and says whom it waits for. Each writes `summary.md`, `errors.txt`, and `warnings.txt` under `build/typecheck/results/`, and prints the path.
  - `make typecheck-mac`: the Mac build, compiled and linked, about 100 seconds.
  - `make typecheck-ios`: the iOS build, strict, about 2 minutes.

  Run them in the Bash tool's background mode, on committed work, one at a time, never in a loop.
- **Tests** go through the build train, which runs every half hour on the orchestrator's schedule and pools every agent's branch.
  - Queue: `python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <branch> --classes <C,D> --areas <a,b>`. The areas come from `python3 Scripts/test/run-area.py --list`. Ask for your own test classes and the classes your change can break, not `all`.
  - Wait in the background: `python3 -I Scripts/agents/wait-for-result.py --agent <slug>`. It exits with your result.
  - A train also counts the iOS errors of the merged tree.
- **New files.** A new Swift file, test or app, needs the Xcode project regenerated. Run `python3 -I Scripts/agents/regenerate-project.py`, which keeps the files' entries and drops xcodegen's reordering of the copy phases, and commit the project with the files.
- **Disk.** Check `df -g /System/Volumes/Data` before a check: below 3 GB free, post to the orchestrator and wait.
- **Shell.**
  - Every `rm` takes literal paths, never a variable.
  - Use `git -C <path>` and absolute paths, since a `cd` lasts into later calls.
  - `sed` here is GNU sed, so use Python for in-place edits (`python3 -I`).

## The board

`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree's root.
- **Start:** register: `bbs register <slug> --role "ONE LINE" --branch <branch> --files <your files and globs>`. Then `bbs claims` and `bbs read --last 10`.
- **During:** read `bbs inbox <slug> --unread` before every check and every commit.
  - Post `commit` after each commit: `--topic "$(git log -1 --format='%h %s')"`, at most 200 characters.
  - Post `finding --file <path>` for a problem in a file you do not own; never fix it yourself.
  - Post `question --to orchestrator` when a decision is not settled by your brief.
- **End:** post `done: <branch>`, then `bbs release <slug> --all`.

## Rules for everyone (the user's, and they override anything else)

- Never push, never `make install`, never merge into main.
- Never read, copy, or write anything of the user's live library, in a test, an experiment, or a review:
  - `~/.TextMouth`;
  - anything under `~/Library/CloudStorage/`, since the user is moving the library to Google Drive tonight;
  - any folder the app's settings name as its data directory.
  - Tests use their own sandboxes, as the existing ones do.
- No test may trap, play sound aloud, or record from a real microphone. Never play, probe, or decode Ogg audio.
- The user reads with VoiceOver and braille. Every sentence a person can hear is a full, plain sentence, and no existing wording, label, or hint changes unless your brief says so.
- Small, focused commits, one logical change each. Each message ends: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Edit no `*.md` file. Your report names the documentation each change needs, and the orchestrator writes it.
- A failing existing test means stop and ask the orchestrator. Never weaken, skip, or work around one.
- Ask nothing of the user: post questions to the orchestrator.

## Usage

The orchestrator watches the weekly usage and stops new work at 60% left. Do not check usage yourself. Commit small and often, so that a stop loses nothing.

## Keeping the cost down

An agent's cost follows its number of calls times the size of its context.
- Read by line range, once.
- Put several patterns in one `grep -E`.
- Make independent calls in one response.

## Your report (your final message)

Write it also to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/readers1104/<slug>-report.md`, which is gitignored and survives a session restart. At most 40 lines:
- the branch, and each commit's hash and subject;
- the files added and changed;
- `make typecheck-mac`'s and `make typecheck-ios`'s result lines;
- the train's result line;
- the comparison with textutil, where your format has one: sample by sample, words and headings;
- what the reader refuses, and with which sentence;
- every function close to a referenced implementation, and from which;
- what you could not verify, your decisions, and the follow-ups, one line each;
- the documentation your change needs, page by page.
