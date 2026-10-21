# Brief: the reader-load race (October 21, 2026)

You are `racefix`, an Opus agent, on the branch `fix/reader-load-race`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"Please investigate the failing tests / send a team to see if its a real problem and fix it."

## What failed
- **The failure.** In a full suite on October 20 (main at e7461fe1), `ReaderRefreshTests.testABookMovedWhileItLoadsOpensFromWhereItIsNow` (`TextMouthProductionTests/ReaderRefreshTests.swift:804`) failed. The next full run, on the same commit, passed. Its three assertion failures:
  - line 814: `reader.errorMessage` was "The file “Tracks” in this audiobook is damaged or incomplete: it cannot be opened as audio. Get a fresh copy of the book, then import it again." (the message is built from `TextMouth/Parsers/AudioMediaProbe.swift:30`);
  - line 815: `reader.content?.chapters.count` was nil, not 2;
  - line 819: the player's loaded URL was nil.
- **What the test does.** It opens a reader on a two-track silent audiobook. While the reader loads in the background, it moves the book into another folder with `moveBooksReturningOutcome`. Its comment says: "Whichever finishes first, the reader ends up loaded, with no error, naming the book's chapter files where they are now, and plays from there."
- **The merge** that ran it changed no reader, audio, or library code, so this is an older race that a busy machine exposed.
- **Background.** The TODO (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`, gitignored, so read it in the main checkout) has a related open note: `grep -n "Still open after T06's branch D merge" TODO-2026-09-04.md`. It describes T06's moves and the "move at every load" backstop. The design is in `TEXT-ANCHORS-RESEARCH-2026-10-10.md`, also in the main checkout; read only the parts about moves and loads.

## What to do
1. **Find the race.** Read the reader's load path for an audiobook (`ReaderViewModel` and its extensions, the audio content loading, and `AudioMediaProbe`) and the library's move (`LibraryViewModel+BookOperations.swift` and the move code).
   - Is it real? Can a user hit it, by moving a book (or renaming its folder, or a library move or sync) while a reader is opening it?
   - What exactly happens? For example, the load reads the old path after the files have moved, and reports the book damaged, when it should retry at the new path.
2. **Prove it with a test that fails reliably without the fix.** Use a hook or seam that holds the load at the racing moment, and add no sleeps. Then fix it, so that the load finds the book wherever it now is, or re-resolves after a move, and a book that really is damaged still says so.
3. **Check the other orders and cases:**
   - the same move with a text book and with a DAISY book;
   - a book renamed during the load, if that path exists;
   - the reverse order: the move finishing before the load starts reading.

   Do not change what a listener hears for a book that really is damaged.
4. **If the race is in the test, not the app,** fix the test so it waits for the right thing, and say so with evidence.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b fix/reader-load-race main`. Register on the message board as `racefix` (`python3 -I .claude/skills/agent-bbs/scripts/bbs.py protocol`), and build only through its wrapper, which `Scripts/test/run-area.py` uses.
- **Commits.** Small focused commits with tests, and code commented as the surrounding code is. Each commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Tests:**
  - no test may trap, play a sound, or record;
  - never touch `~/.TextMouth` or `UserDefaults.standard`;
  - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first.
- **Disk.** Check for 4 GB free before a build. Delete your build folder at the end, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Workers.** No subagents; do it yourself.
- **Never** push or merge into main.
- **At the end,** in one `run-area.py` invocation, run:
  - `ReaderRefreshTests` with `--repeat 5`;
  - the areas holding the reader's loading and the library's moves (find them in `Scripts/test/areas.conf`);
  - every class you touched.

  Also run `make lint-tests LINT_BASE=main`. Do not run the full suite; the orchestrator runs it at the merge.

## The report (your final message, at most 35 lines)
- Is it a real race? What happens, step by step, with file and line references, and can a user hit it?
- The fix, and each commit with its subject.
- The new test, and proof that it fails without the fix.
- The exact counts, including the five repeats.
- Any other race you found but did not fix, as follow-ups.
