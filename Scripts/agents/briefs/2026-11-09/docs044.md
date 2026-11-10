# Documentation for 0.4.4 (November 10, 2026)

You are `docs044`, a Sonnet docs agent, on branch `docs/0.4.4`. Write the documentation for the quit fix and the iPhone's Search in Book. They are merged into `integration/0.4.4` at **044cf7f4**, which goes to main once its full suite passes. Edit Markdown only. Build nothing, run no tests, and leave the version number alone: the orchestrator sets 0.4.4.

## Start

- Make your branch at the merge: `git switch -c docs/0.4.4 044cf7f4`, and check that `git log -1 --format=%h` prints `044cf7f4`.
- Read the reports below, which name the documentation each change needs. Where a report and the code disagree, the later report and the code win.
- Then read the pages you edit, and the code each sentence describes.

## What to document

1. **The quit fix** (`fix/quit-while-held`). Reports, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/quitfix/`: `quitfix-report.md`, `quitfix-fix-report.md`, `quitfix-review.md`, `quitcheck-report.md`.
   - `docs/architecture/launch.md` and `docs/architecture/state/saving-failures.md`:
     - the quit sequence;
     - `QuitRequest.ask()`;
     - `QuitFinisher`, which cancels, finishes, and asks again;
     - `QuitReason`, with `kAEQuitReason` and the power-off window;
     - a session end answered later;
     - the kinds of work;
     - the single-line `quit-ok:` rule;
     - the two AppKit facts the probes showed.
   - `docs/architecture/state/feeds.md` and `state/exports.md`:
     - a quit now cancels, says what it finishes, and asks again;
     - downloads stopped for a quit that is then cancelled stay stopped.
   - `docs/developer/testing.md`: `Scripts/test/quit-while-held.py`, its 11 cases, and the scan.
   - `docs/user/feeds.md` and `docs/user/speed-and-memory.md`:
     - what a listener hears and sees when quitting during downloads, a re-read, or an export, quoting the panel's words from the code;
     - a log out or shut down waits for the work as before.
2. **The iPhone's Search in Book** (`ios/search-1109`). Reports, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/`: `iossearch-report.md`, `iossearch-fix-report.md`, `iossearch-review.md`, `searchcheck-report.md`.
   - `docs/architecture/platforms.md`:
     - `PhoneBookSearch`, `PhoneSearchSheet`, `PhoneFocusRequests`, and the registry's tickets;
     - the six-row grid;
     - `offersTranscription`;
     - `BookSearchModel`'s `debounceInterval`;
     - `PhoneLaunchRequest`'s three variables.
   - `docs/developer/testing.md`: the `SearchUITests`, and the counts.
   - The spec, `IOS-INTERFACE-SPEC-2026-11-07.md`, staged with `git add -f`:
     - Search in Book is built;
     - the grid has six rows;
     - the focus rule exempts landings on Back and the title.
   - The Mac's `BookSearchWording`, wherever the Mac's search is described.
3. **The changelog,** `docs/user/changelog.md`: a section for 0.4.4, dated November 10, 2026, in the form of 0.4.3's.
   - Say what a listener notices about quitting:
     - the hang after Quit Anyway or a save is gone;
     - a second Command-Q no longer cuts work off;
     - what is said;
     - log out.
   - The iPhone work is unshipped, and stays out.

## How to write, the rules, and the report

Follow these sections of `Scripts/agents/briefs/2026-11-08/docsios.md` exactly:
- "How to write";
- "Rules that every agent follows (word for word)";
- "Your report".

Report the branch's tip and commits in 20 lines at most.
