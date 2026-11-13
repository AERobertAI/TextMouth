# What every agent of November 13, 2026 follows

On November 13 main is **130f6788**: version 0.4.6 (tag `v0.4.6`), the iPhone interface tests on GitHub, and briefs. The user still runs 0.4.2. The user is blind and reads with VoiceOver and a braille display: what VoiceOver and braille read is the design.

## The user's word on usage for this run

On November 13 the user said: "don't worry about the usage limit that much, I want to use it all up and I have several resets that can get it back to 0 again." So keep working until the API refuses you, whatever the usage script says. The scoped window "Weekly (Fable)" never applies to you. Commit small and often, so a cut-off loses nothing: the orchestrator resumes you after a reset.

## Start

- Your worktree may start at an old `origin/main` (05327665). Make your branch at local main: `git switch -c <your branch> main`, then check that `git merge-base --is-ancestor 130f6788 HEAD && echo ok` prints `ok`.
- Briefs are gitignored, so read them from the main checkout: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/briefs/2026-11-13/`.
- Read `AGENTS.md` first ("How a task agent works" and "Lessons that cost time"), then only the pages of `docs/architecture/` that your work touches (`ARCHITECTURE.md` is their index).
- Read "Making each train count" in `docs/agents/working-with-agents.md`, and "Tests on GitHub Actions" in `docs/developer/testing.md`.
- Register on the message board (`.claude/skills/agent-bbs/`) with your name, your branch, and the files you edit (`bbs register`, then `bbs claims` and `bbs read --last 10` for overlaps). Check your inbox before each batch of commits and before your report.

## Other agents working today

Each owns its region; post a `finding` on the board for a problem in another's region and leave it alone.

- `wintimer` (Opus): the sleep timer, one per reader window. `SleepTimerService`, `ReaderViewModel+SleepTimerHandOver`, `+BookMoves`, `+NextBookWindow`, the timer parts of `+Playback`, `SleepTimerView`, `BookReaderWindowView`, and the timer's menu commands.
- `articles` (Opus): leading articles in title sorting, display, and letter navigation. `LibraryBookSorter`, the Library list's rows and keyboard handling in `LibraryView`/`LibrarySubviews`, and a new setting in the Library tab.
- `libsearch` (Opus): searching the whole library's text. New files, Search in Book's engine (`BookSearchEngine` in `BookSearchView.swift`, `BookSearchModel`), and a new command.
- `rlfinished` (Sonnet): the Reading List's "remove finished books" option. `ReadingListOptionsBar`, the reading list model and its view models.
- `optaudit` (Fable): an audit of the app's size, memory, and processing. Read-only; builds Release variants under the lock.
- `triage1113` (Sonnet): reads the TODO's open items. Read-only.
- `iosunitfix2` (Sonnet): the iPhone unit tests on GitHub. `Scripts/agents/`, `TextMouthiOSUITests/`.
- From 01:00, the TODO's batches (Sonnet), each owning the files section 2 of `build/orchestrator/nov13/triage-report.md` lists for it: `batchA` (import edges), `batchB` (parser safety), `batchC` (replace and encodings), `batchF` (metadata and Book Information).

`ConfigService`, `SettingsViewModel`, `MenuCommands`, `AppDelegate`, `KeyboardShortcuts*`, and the config test fixtures are shared: add your lines next to, not into, other agents' lines, and expect adjacent-line conflicts when you rebase (keep both sides).

## Building and testing

- **Nothing builds or tests on this Mac except through the heavy-work lock.** Trains run on GitHub Actions:
  1. commit;
  2. `make typecheck-tests REF=<commit>`;
  3. `python3 -I Scripts/agents/build-train.py request --agent <name> --branch <branch> --classes <A,B> --areas <x,y>`, naming every class your change could break;
  4. wait with one background `python3 -I Scripts/agents/wait-for-result.py --agent <name>`, and use the wait to review your own diff. A train leaves 5 minutes after the first waiting request and takes 3 to 4 minutes; it tests the commit your branch was at when you asked, so ask again after a later commit.
- **Type-checks.** Run `make typecheck-mac` and `make typecheck-ios` once for each batch that changes Swift, after committing, since they check HEAD's commit. Never wrap any `make typecheck-*` in `run_locked.py`: they take the lock themselves. The iPhone target must stay at 0 errors: shared code under `TextMouth/` compiles for both platforms; Mac-only interface goes in `TextMouth/Platform/macOS/` or under `#if os(macOS)`.
- **Anything else heavy on this Mac** (a build, a benchmark, a fuzz run) goes through the lock: `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/run_locked.py <name> <command...>`.
- **A new test file** needs `make generate` and the committed `project.pbxproj`; put each new test class in `Scripts/test/areas.conf` (`python3 Scripts/test/run-area.py --unassigned` lists the ones missing).
- **Policy tests to name in your requests** when your change calls for them: a new `@unchecked Sendable` type or `nonisolated(unsafe)` variable, `UncheckedConcurrencyPolicyTests`; a new log tag, `LogContentPolicyTests`; a new shortcut action, `KeyboardReachabilityTests` and the legacy shortcut scenarios; a new field on `Book`, `ContentAnalysisMergeTests`; a stored format, `OnDiskContractTests`; a new setting, the config fixtures' tests.
- **Never put a deliberate break on a shared train.** Prove a break with a small harness in a scratch copy through `run_locked.py`, with a GitHub run of your own tree sent by hand, or by reading the code where only the hosted app can show it.
- **Never run `gh run watch`.** `github_run.py` already polls GitHub, and duplicate watchers used up the account's API limit on November 11.
- **Before your report:** rebase onto local main (keep both sides of adjacent-line conflicts), then run the full suite once on GitHub: `python3 -I Scripts/agents/run_suite.py --remote <commit> <name> build/orchestrator/<name>/final.log` as a background task, and record its exact `Executed N tests, with S tests skipped and F failures` line. The orchestrator's Mac suite is the merge gate.
- **Disk.** About 14 GB is free. Keep your scratch in `build/orchestrator/<your name>/` of the main checkout, and report how much you add.
- **Versions.** If your change alters what a reader makes of a book, raise that reader's version in `PageReaderVersions` or its own version constant, and say so. Leave the app's version and the changelog alone: the orchestrator sets them when it merges.

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Never search from `/` or the home folder** (`find`, `bfs`, `mdfind`, `du`, `ls -R`): it walks the user's Downloads, Documents, Music, and cloud drives and puts macOS privacy prompts on their screen. Search only the repository, the package checkouts in `build/DerivedData/SourcePackages/checkouts/`, and Xcode's own folders.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name. The one exception is `libsearch`'s, which its own brief defines exactly.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push (except to `TestBuild`, only through `github_run.py`, `run_suite.py --remote`, or a train), never `make install`, and never merge into main.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, libwpd, or any other GPL or LGPL project.
- Downloaded files are untrusted: put each in its own new, empty folder, keep your scripts elsewhere, and run any Python that reads them as `python3 -I -B`.
- Use they/them for the user. Don't send the user's email address anywhere.
- When unsure, carry on with the safest choice and say so in the report. Ask the user nothing; write your questions, each with its recommended answer, in the report, and build the recommended answer.

## Code

- Every control is reachable by the keyboard and speaks its label, value, and hint to VoiceOver; nothing is conveyed by sight alone. Announcements go through the app's existing announcement helpers.
- Comment every function you write or change, and every non-obvious block. Keep it DRY: one helper, not two copies.
- Every user-visible string lives in a `…Wording` enum, as the code around it does, so tests can name it.

## Commits and report

- Commit small and often. Each message says what changed and what checked it, and ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`, or your own model's line (`Claude Opus 5.5`, `Claude Fable 5.2`).
- Edit no Markdown file unless your brief says so.
- Your final message is the report, 60 lines at most; save it also as `build/orchestrator/nov13/<your name>-report.md` in the main checkout:
  - the branch, its tip, and its commits (hash and subject);
  - each item of your brief: what you changed, or why not, and the test that proves it;
  - for each fix, whether breaking it in a scratch copy fails a test;
  - the trains, the type-checks, and the full suite, with their exact counts;
  - the disk you added;
  - what you couldn't verify;
  - your decisions and the questions for the user, each with the answer you built;
  - the documentation each change needs, page by page under `docs/`.
