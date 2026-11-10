# What every agent of November 9, 2026 follows

On November 9 the user installed 0.4.2 and asked to keep working on the follow-ups of the November 8 merges. Main is **e0ea3b9d**, version 0.4.2. The user is blind and reads with VoiceOver and a braille display: what VoiceOver and braille read is the design.

## Start

- Your worktree may start at an old `origin/main`. Make your branch at main: `git switch -c <your branch> e0ea3b9d`, and check that `git log -1 --format=%h` prints `e0ea3b9d`.
- Read `AGENTS.md` first, then only the pages of `docs/architecture/` that your work touches (`ARCHITECTURE.md` is their index).
- Read "Making each train count" in `docs/agents/working-with-agents.md` and follow it. Trains leave once an hour, on the hour, and heavy jobs run one after the other. While you wait for one, review your own diff, fix what you find, and make each test's failure message say what it found.
- Register on the message board (`.claude/skills/agent-bbs/`) with your name, your branch, and the files you edit. Check your inbox before each train request, before each batch of commits, and before your report.

## Checks

- **The train.** When your branch changes Swift, send one request naming every area and every class your change could touch:
  `python3 -I Scripts/agents/build-train.py request --agent NAME --branch BRANCH --areas A,B --classes X,Y`.
  Then wait for it with one background `python3 -I Scripts/agents/wait-for-result.py --agent NAME`. A request made before the hour leaves on that hour's train. Fix every failure it reports in one round, then ask once more.
- **Never put a deliberate break on the train.** The train tests every request together in one tree, so a branch with a fix broken on purpose fails other agents' classes. Prove a break with a small harness in a scratch copy, run through `run_locked.py`, or by reading where only the hosted app can show it.
- **Type-checks.** Run `make typecheck-mac` and `make typecheck-ios` once for each batch, after committing, since they check HEAD's commit. Before a train request, also type-check the tests on your commit: `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/ios/typecheck.py --platform macos --tests --ref <your commit>`. Never wrap any of them in `run_locked.py`.
- **Anything else heavy** (a Release build, a fuzz run, a simulator pass) goes through the heavy-work lock:
  `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/run_locked.py <name> <command...>`.
- **Disk.** About 12 GB is free. Keep your scratch in `build/orchestrator/<your name>/` of the main checkout, and report how much you add.
- **Versions.** If your change alters what a reader makes of a book, raise that reader's version in `PageReaderVersions` or its own version constant, and say so in your report. Leave the app's version and the changelog alone: the orchestrator sets them when it merges.

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, libwpd, or any other GPL or LGPL project.
- Downloaded files are untrusted: put each in its own new, empty folder, keep your scripts elsewhere, and run any Python that reads them as `python3 -I -B`.
- Use they/them for the user. Don't send the user's email address anywhere.
- When unsure, carry on with the safest choice and say so in the report. Ask the user nothing.

## Commits and report

- Commit small and often. Each message says what changed and what checked it, and ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`, or your own model's line.
- Comment every function you write or change. Keep it DRY: one helper, not two copies.
- Your final message is the report, 40 lines at most:
  - the branch, its tip, and its commits;
  - each item of your brief: what you changed, or why not, and the test that proves it;
  - for each fix, whether breaking it in a scratch copy fails a test;
  - the trains, the type-checks, and any other runs, with their counts;
  - the disk you added;
  - what you couldn't verify;
  - the documentation each change needs, page by page (you edit no Markdown unless your brief says so).
