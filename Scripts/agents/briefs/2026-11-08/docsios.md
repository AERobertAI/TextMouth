# Documentation for the iPhone interface's first run (November 8, 2026)

Write the developer documentation for what `ios/lead-1108` adds: the iPhone interface built from the spec, its first run in the simulator, and its tests. Edit Markdown only: the pages under `docs/`, `ARCHITECTURE.md` or `README.md` if an index needs a new line, and the spec named below. Build nothing, run no tests, and leave the version and the changelog alone: the iPhone app hasn't shipped.

## Start

- Your worktree may start at an old `origin/main`. Make your branch at the lead's tip: `git switch -c docs/ios-1108 1fefa2cf`, then check that `git log -1 --format=%h` prints `1fefa2cf`.
- Skip the long start-up reading. Read the pages you edit, the report below, and the code each sentence describes.
- Usage: don't check it.

## What to document

The lead's report names every page and topic, in its section "The documentation each change needs": `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/ioslead-report.md`. The review beside it, `review-code-1108.md`, explains the parts the fixes changed. Where a report and the code disagree, the code wins.

1. **`docs/architecture/platforms.md`:** how the iPhone app is put together and its new parts. Name each in the code's own words:
   - `PhoneLaunchRequest`, which exists only in debug builds;
   - `PhoneSession.readerMade`;
   - `ReaderPhoneHooks.unitInForce`;
   - the crash guard read when the session is made;
   - `PhoneScreenHolds`;
   - the announcement priorities on iOS;
   - `PhonePassagePolicy.placeToShow` and `turnEffect`;
   - `PhoneEscapePolicy`;
   - the error alert plan, Speech Stopped, and the preview's pause;
   - the one iOS plist, and what `Scripts/ios/sync-info-plist.py` adds to it.
2. **`docs/developer/building.md`:** building `TextMouthiOS` for the simulator.
   - The committed scheme, the one build folder (`build/DerivedData-ios.noindex`), and iPhone 17 only.
   - Every simulator build or test run goes through `run_locked.py`, never a clean build.
   - The `SIMCTL_CHILD_` launch variables.
   - A device's first boot adds about 2.1 GB.
3. **`docs/developer/testing.md`:**
   - the `phone` area;
   - the two iOS test targets and how to run them;
   - the audit findings that are accepted, each with its reason;
   - in the simulator, never press Play and never type;
   - the type-checks don't compile tests, so only a train or a simulator build finds a compile error in a test file.
4. **The spec**, `IOS-INTERFACE-SPEC-2026-11-07.md` in the repository root, staged with `git add -f`:
   - its hand-check list gains Read All and the scrub (the escape gesture);
   - its Book content section says what a chapter with no words shows: the next chapter with words, the ones Play reads.

Leave `docs/user` alone: an iPhone page waits until the user has run the app on their own phone.

## How to write

- The user reads these pages with VoiceOver and a braille display. Write headings, and short bullets of whole sentences. Never write a paragraph thousands of characters long. Siblings are siblings, never children of their first sentence.
- Quote the app's own sentences from the code, not from the reports. Search the code for each sentence you quote.
- Where a report and the code disagree, follow the code and list the disagreement in your report.
- Commit small and often, one page or one topic each. Commit messages end with:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk is tight** (about 12 GB free). Keep your scratch under 500 MB.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, libwpd, or any other GPL or LGPL project.
- Use they/them for the user. Don't send the user's email address anywhere.
- When unsure, carry on with the safest choice and say so in the report. Ask the user nothing.

## Your report

Your final message is the report. Don't try to write it outside your worktree; the orchestrator saves it. Keep it to 40 lines at most. Give:
- the branch, its tip, and its commits, with the pages each topic touched;
- where the report and the code disagreed;
- what you couldn't confirm in the code;
- pages that need more than you could give them.
