# End of heading, set where there is nothing to read (November 11, 2026)

You are `endheading`, a Sonnet worker, on branch `fix/end-of-heading-silent-start`. First read `../2026-11-10/common.md` and follow it, except where this brief says otherwise: your start commit, and Markdown.

## Start

- Make your branch at main **49b9e597** (version 0.4.5), not at the commit `common.md` names: `git switch -c fix/end-of-heading-silent-start 49b9e597`. Check that `git log -1 --format=%h` prints `49b9e597`.
- Read the outside review that found this bug, finding 3 of `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosuitests/iosuitests-review.md`. Read only that finding; the rest belongs to another branch.

## The bug

The iPhone's interface tests found it, and the review traced it to code the Mac shares:
- A new Project Gutenberg EPUB opens at chapter 0, its "Cover", which is only an image.
- The listener chooses the sleep timer's End of heading ("Stop at the end of this heading and start playing").
- `startSleepTimer` (`ReaderViewModel+Playback.swift`, near line 3205) saves `headingAfterCursor`: the first heading after chapter 0, which is chapter 1's first heading.
- Play skips chapters with nothing to say (`speechStart`, near line 677), so playback starts at chapter 1, offset 0: at that same heading.
- The first cursor refresh, `endSleepTimerAtHeadingEnd`, finds that heading begun, and stops playback at once. VoiceOver says "Sleep timer expired at the end of the heading. Playback paused." The listener heard nothing, and the timer reads Off.

## What the spec says

`docs/user/reader-windows.md`, in the sleep timer's paragraph: "End of heading pauses playback where the heading playing ends: within a chapter, where the next heading begins". The heading playing is the one playback starts in. A timer set on the cover must stop where the heading after chapter 1's first heading begins, not at chapter 1's first heading.

## The work

1. **Find every way to meet it.** The heading a timer waits for is taken from the cursor in three places: `startSleepTimer`, `refreshSleepTimerHeading` (`ReaderViewModel+SleepTimerHandOver.swift`), and the hand-over and restart paths that call it. Any place where Play starts later than the cursor gives the same bug:
   - a chapter that is only an image;
   - the end of a chapter after its last words;
   - a section the reader's settings leave out (a removed section);
   - a book whose first chapters are empty.
   Say which of these you found, and whether the Mac opens a new EPUB at its cover, as the iPhone does.
2. **Fix it in the shared code, once.** The heading a timer waits for is the first heading after the place where playback reads, not after the cursor, whenever the two differ.
   - Use the logic that already decides where Play begins. Don't write a second copy of it. `PhonePassagePolicy` documents the same place for the iPhone's Book content; if the two can share one helper, make them share it.
   - Leave unchanged everything the spec already describes: a timer set at a heading's own start, a timer set while playing, a chapter that opens with its heading, a chapter with text before its first heading, and the book's end.
   - Change no reader's output. If you find that you must, stop and say so in the report.
3. **Tests (Mac unit tests).**
   - A test reproduces the bug as the iPhone met it: an EPUB fixture whose chapter 0 is only an image, End of heading set at chapter 0 with "and start playing", and playback not stopped at chapter 1's first heading. It fails on 49b9e597.
   - It stops where the next heading begins.
   - Add a test for each other case of step 1 that you find, and say for each whether it fails without the fix.
   - Use an existing test fixture or a small one made in the test. Use no copyrighted book, and no Ogg.
4. **Documentation.** This branch may edit:
   - the sleep timer's paragraph in `docs/user/reader-windows.md`;
   - the iPhone's sleep timer sentences, if `docs/user/` has them;
   - the architecture page that covers the sleep timer.

   Add one sentence: a timer for the end of the heading set where there is nothing to read, as on a book's cover, waits for the end of the heading that playback starts in. In your report, draft the changelog lines for 0.4.6, in the changelog's style. Don't edit `docs/user/changelog.md`.

## Not yours

- Branch `ci/ios-ui-tests` is changing `TextMouthiOSUITests/`, `Scripts/agents/`, and `.github/`, all at once. Touch none of them. Its `PlaybackUITests` keeps End of the book until both branches merge.
- The value the running timer reads, "9:57 remaining", is a separate question. Leave it.

## Trains

- Request trains as `docs/agents/working-with-agents.md` says, naming every class your change could break: the sleep timer's tests, the reader's playback and navigation tests, the hand-over tests, and the iPhone's `PhonePassagePolicyTests` if you touch it. Run `make typecheck-tests REF=<commit>` before each request.
- Trains share TestBuild with the other branch's long GitHub runs, so expect waits. Use them to review your diff.
- To prove that a new test fails without the fix, send a GitHub run of your own tree with the fix taken out: `python3 -I -B Scripts/agents/run_suite.py --remote` or `github_run.py`, naming only your classes. Never put the break on a train.
- **Pushing:** you may push to `TestBuild` only, and only through `github_run.py`.
  - Never push to main or any other branch, never push a tag, and never delete a remote branch.
  - The repository is public. Push only commits of tracked files, nothing from `build/`, `humanQuestions/`, or `humanReports/`, and no secret.
  - Never change the repository's settings, never start a workflow by hand, and never cancel a run you didn't start.

## Your report

Follow `common.md`'s list, in 40 lines at most. Also include:
- which of step 1's cases you found, and on which platform;
- the changelog lines you drafted;
- whether each new test fails on 49b9e597.
