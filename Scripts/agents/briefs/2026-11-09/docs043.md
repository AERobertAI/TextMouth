# Documentation for 0.4.3 (November 9, 2026)

You are `docs043`, a Sonnet docs agent, on branch `docs/0.4.3`. Write the documentation for what tonight's branches changed. They are merged into `integration/0.4.3` at **4dccd34d**, which goes to main once its full suite passes. Edit Markdown only. Build nothing, run no tests, and leave the version number alone: the orchestrator sets 0.4.3.

## Start

- Make your branch at the merge: `git switch -c docs/0.4.3 4dccd34d`, and check that `git log -1 --format=%h` prints `4dccd34d`.
- Read the reports, which name the documentation each change needs. Where a report and the code disagree, the later report and the code win.
- Then read the pages you edit, and the code each sentence describes.

## What to document

1. **The iPhone's audit findings** (`ios/fix-d-1109`). Reports: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/iosfixd-report.md` and `iosfixd-fix-report.md`, and the review `iosfixd-review.md` beside them (its finding 7 lists the false lines).
   - `docs/developer/testing.md`, the iPhone section:
     - the probe and `ToolbarPlacementProbeUITests` are gone;
     - the audit runs each kind alone, from one table of kinds;
     - the accepted kinds, and why each is accepted;
     - `LargeTextUITests` fails on Dynamic Type and clipped text again, except those;
     - the sheet taps retry;
     - the counts: 21 UI tests and 19 unit tests.
   - `docs/developer/building.md`: the probe's launch variable is gone, and a simulator pass needs a new result-bundle name each time.
   - `docs/architecture/platforms.md`:
     - `PhoneLaunchRequest` is debug-only;
     - `PhoneSheetButton` has no probe;
     - `PhoneTextStyle` cites the spec sections by their names.
   - The crash guard's page (find it from `ARCHITECTURE.md`): the reopen keys are cleared with the guard as the session is made, and the verdict keeps the keys of a book opened since.
2. **The KF8 follow-ups** (`readers/kf8-followups`). Reports: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/kf8follow-report.md`, `kf8follow-fix-report.md`, `kf8follow-review.md`, `kf8check-report.md`.
   - `docs/architecture/state/imports.md`, the KF8 items:
     - the repeated-title exception, now only when a piece opens in no section element;
     - the licence-opening rule;
     - MOBI 6 leaving soft hyphens out.
   - `docs/architecture/shared-helpers.md`: `ParserUtilities.removingSoftHyphens`, the spellings it catches, and its measured effects on search, braille, and speech.
   - `docs/architecture/platforms.md`: `ADDED_EXTENSION` is gone.
   - `docs/developer/testing.md`, the KF8 lines:
     - the new samples and tests;
     - the fuzz kit, now built and run, with its modes;
     - remove "never been built or run".
3. **The older follow-ups** (`fix/followup-sweep-2`). Reports: `sweep2-report.md`, `sweep2-fix-report.md`, `sweep2-review.md`, `sweep2check-report.md`, in the same folder.
   - `docs/user/what-textmouth-reads.md` (around line 423) and `docs/user/library-window.md` (around line 29): how unmarked UTF-16 and UTF-32 are found now, and that short Chinese, Japanese, or Korean UTF-16 text with few spaces, digits, or line ends isn't.
   - `docs/user/adding-books.md`, and the storage pages:
     - a book folder that is a link;
     - the message for a book stored outside the data directory, and what Replace Existing does then;
     - the DOCX title and creator fallbacks;
     - the damaged-file sentence;
     - the DAISY notice.
4. **The Mac app's size** (`build/mac-size`, no commits). Report: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/macsize/macsize-report.md`.
   - `docs/developer/building.md`'s size sentence, which still says about 20 MB:
     - the Release executable is 22.7 MB and the bundle about 23 MB, against the 25 MB target;
     - `TextMouth/Phone/` keeps 59 KB after the linker strips it;
     - SwiftSoup (3.0 MB) and swift-markdown (0.6 MB) are the largest pieces;
     - `LD_MAP_FILE_PATH` on the command line breaks the build, and `LD_GENERATE_MAP_FILE=YES` alone gives the maps.
5. **The changelog,** `docs/user/changelog.md`: a section for 0.4.3, dated November 9, 2026, in the form of the sections before it.
   - Say what a listener notices: Kindle books, then plain text and HTML books, are read again once at the first launch, with the place following the words; A Modest Proposal's chapters; the encodings now found; linked folders; the clearer messages.
   - The iPhone work is unshipped and stays out. The tools stay out.
   - Leave a line for the transcript fixes, which merge later tonight: `<!-- transcripts -->`.

## How to write, the rules, and the report

Follow these sections of `Scripts/agents/briefs/2026-11-08/docsios.md` exactly:
- "How to write";
- "Rules that every agent follows (word for word)";
- "Your report".
