# Working on TextMouth with coding agents

This file holds what every agent session must know, whether it orchestrates or works on one task.
The orchestrator's own rules are in [Orchestrating TextMouth's agents](docs/agents/orchestrator.md).

## Start here

- [`docs/agents/writing-docs.md`](docs/agents/writing-docs.md): how every page and memory file is written.
- [`README.md`](README.md): the index of the documentation in `docs/`.
- [`ARCHITECTURE.md`](ARCHITECTURE.md): the index of the code's parts; read only the pages your task touches.
- [`.claude/skills/doc-library/SKILL.md`](.claude/skills/doc-library/SKILL.md): find and check a doc section; `doclib affected` for a branch.
- [`.claude/skills/agent-bbs/SKILL.md`](.claude/skills/agent-bbs/SKILL.md): the message board the agents coordinate through.
- [`docs/agents/working-with-agents.md`](docs/agents/working-with-agents.md): the board, and making each train count.
- [`docs/agents/history.md`](docs/agents/history.md): earlier campaigns' status, and the stories behind these rules.
- [`TODO-2026-09-04.md`](TODO-2026-09-04.md): the record of every merge, and the open items.
- [`AGENT-NOTES-2026-10-04.md`](AGENT-NOTES-2026-10-04.md): what agents left unverified; read it before a documentation pass.
- [`research/README.md`](research/README.md): the research and design documents, each ending in the user's answers.
- `*.md` is gitignored except README.md, AGENTS.md, ARCHITECTURE.md, CLAUDE.md, and the pages under `docs/`: stage other Markdown with `git add -f`.
- `humanQuestions/` (in the main checkout only) holds the user's questions and answers: read its newest file before asking anything again, and put new questions in a new file.

## The user's standing rules

- Never install: the user runs `make install` themselves when told main is ready.
- Task agents never push, except to `TestBuild` through the train tools.
  Only the orchestrator pushes main and its version tags, and only at a version bump it judges a fairly stable release: a green full Mac suite on that tree, `make check` passed, and nothing private in the commits (no path under `build/`, `humanQuestions/`, or `humanReports/`).
- `github_run.py`'s workflow guard is on: a change to `.github/workflows/` or `.github/actions/` runs on `TestBuild` only after it is on GitHub's main, so it ships with a release push after an outside review.
- Nothing on this Mac may start an iPhone simulator: the iPhone tests run on GitHub, and `make typecheck-ios` needs only Xcode's SDK.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment; copy what a test needs into its own sandbox, and read its logs only for a diagnosis.
- Only the orchestrator merges into `main`, with `git merge --no-ff` and only after the full hosted suite is green on the merged tree; the project `CLAUDE.md` otherwise forbids merging.
  Every merge is recorded in the TODO and described in the pages under `docs/` by a documentation pass.
- Follow `CLAUDE.md`'s Code Style, Git Workflow, and Accessibility; each commit has a test, and every control is keyboard-operable with every value spoken.
- No test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object), since the user sees a macOS crash dialog for every test host that aborts.
- No test may play sound aloud or record from a real microphone without an opt-in environment variable.
- Clear only TextMouth's own caches: other apps' caches and the user's Trash are theirs.
- The usage rule in the user's global instructions (wrap up when a limit is nearly spent) holds unless your launch message says the user overrode it; then keep working until the API refuses you, and leave unmerged branches on their worktrees for the reset.

## How a task agent works

The orchestrator launches each agent in its own git worktree under `.claude/worktrees/` with a brief.
The brief names the branch, a task slug, the regions to avoid, the numbered items (one commit each) with their tests, the baseline test count on main, and the report format.
The agent:

1. Makes its branch from `main` (or the team branch its brief names), since a worktree can start on an older commit.
   It reads this file and its brief, registers on the board as its slug with `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <paths or 'quoted globs'>`, then runs `bbs claims` and `bbs read --last 10` for overlaps.
   `bbs protocol` prints the full rules.
2. Reads its inbox (`bbs inbox <slug> --unread`) before every commit, train request, and report.
   It posts a `commit` notice after each commit (`--topic "$(git log -1 --format='%h %s')"`), a `finding` with `--file <path>` for a problem in files it does not own (never fixing it), and a `question` when a decision touches another agent's work.
   It ends with `done: <branch>` and `bbs release <slug> --all`; posts are short, and the board's topic limit is 200 characters.
3. Tests through the build train and never builds on its own: it commits, runs `make typecheck-tests REF=<commit>`, and queues `python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <branch> --classes <A,B> --areas <x,y>`, naming everything its change could break.
   It waits with one background `python3 -I Scripts/agents/wait-for-result.py --agent <slug>`.
   [Making each train count](docs/agents/working-with-agents.md) in `working-with-agents.md` has the rest; Tests on GitHub Actions in [Testing TextMouth](docs/developer/testing.md) says how to read a result.
   A new test file needs `make generate` and the committed `project.pbxproj`, which the train regenerates and so never notices missing.
4. Commits one logical change at a time, each message ending with the attribution the session's own instructions give, and leaves files outside its task alone except for a hook its brief names.
   It edits no `*.md` file, with two exceptions: it fixes the citations of any page its change leaves stale, when the change renames or removes a path or type that page cites (`doclib stale` lists them), and it adds one line to the doc-library `SKILL.md` for a new subcommand.
   The rest of the docs stay the documentation pass's, from the agent's report.
5. Before reporting, rebases onto `main`, keeping both sides of adjacent-line conflicts (common in `ConfigService`, `SettingsViewModel`, `MenuCommands`, `AppDelegate.applicationShouldTerminate`, and the config test fixtures).
   It type-checks the tests, requests one last train naming every area its change touches, records that train's exact `Executed N tests, with S tests skipped and F failures` line, and releases its claims.
   When its change could alter the Release build or the app's size, it also runs `make check SIGN_APP=true` (The make check gate, in [Building TextMouth](docs/developer/building.md)).
6. Reports: the branch; the commits with hashes and subjects; the files changed; the train's exact result; what it could not verify; its decisions and assumptions; and its findings posted on the board.
   It also reports the documentation wording its changes need, naming the page under `docs/` each sentence belongs on, and the sections `doclib affected` lists for its branch.

## Lessons that cost time

- `git merge -F -` does not read standard input; write merge messages to files.
  Two heredocs on one command line swallow the second; write helper scripts to files first.
- Every agent of one session shares the session's scratchpad folder: on October 9, 2026 one agent's commit-message files were overwritten by another's after use.
  Each agent prefixes its scratch files with its slug (or keeps a subfolder named for it), and the orchestrator's own start with `orchestrator-`.
- Agents can stall with "no progress for 600s"; a message to the agent's id resumes it with its context intact, and its branch keeps its commits.
  A background suite stopped at its time limit must be rerun.
- An agent that follows the usage rule stops itself at a "critical" reading; say in the launch message when the user has overridden it.
- Keep two gigabytes free before a merge suite: the archive-import tests refuse to run under the app's one-gigabyte reserve.
- A hosted SwiftUI view whose width outgrows the width offered (a macOS form in the columns style did) makes its window chase it until AppKit raises "more Update Constraints in Window passes than there are views in the window" and the test host ends with a crash dialog the user sees (twice on October 10, 2026).
  Host such views inside a fixed frame, or measure them with `NSHostingController.sizeThatFits(in:)` and no window.
- An agent's worktree (`isolation: "worktree"`) starts at origin/main, which can be far behind local main (1,081 commits on October 12, 2026): every brief has its agent make its branch from local main or a team branch, by name.
- A changed copy of `bbs.py` must never run against the live board: one worker did on October 12, which created the new tables early (harmlessly).
  Point `TEXTMOUTH_BBS_DIR` at a scratch folder first.
- A test host that joins the system's media session takes the user's AirPods; it never does now, but a branch older than that fix still can until it rebases.
- A tool call that waits on a permission prompt stops its agent until the user answers, and the user may be away.
  Claude Code asks before an `rm` through a shell variable: on October 18, 2026 a team lead's `rm -f "$D/$out"` in a throwaway test loop waited five hours while its team stood still.
  Every `rm`, in a brief or the orchestrator's own commands, takes literal paths.
  While agents work, the orchestrator runs `python3 -I Scripts/agents/stall-watch.py --subagents ~/.claude/projects/<project folder>/<session id>/subagents` as a background task; it exits naming any agent whose tool call has waited fifteen minutes for its result.
- The Agent tool runs at most 20 subagents at once in a session ("Concurrent subagent limit reached (20)").
  Count the leads, reviewers, and workers before a launch: on October 30, 2026 two leads built most of their tasks themselves because they could not launch workers.
- Nothing re-invokes the orchestrator when a spent usage window comes back, and once the limit is reached the orchestrator cannot start a watcher either.
  At the start of any long unattended run, start `Scripts/agents/wait-for-usage-reset.py` as a background task: it exits, re-invoking the orchestrator, when a window it saw spent has headroom again.
  On October 31, 2026 the 5-hour window reset at 03:20 and every agent stood still until 12:06.
- A revert must keep what other code uses.
  Reverting a commit also takes away the helpers it added: on October 31, 2026 a revert removed the test helper `onWorkerSizedStack`, which other tests used, and the next build failed.
  Before a revert, grep for each symbol the commit added.

## Where things stood on November 14, 2026

- Main is at version 0.4.10 (tagged `v0.4.10`; `v0.4.9` at 8918f4ee and `v0.4.8` at 82e68c0d; all three unpushed, and the user still runs 0.4.2).
  The Release app is 18.3 MB (18,291,664 bytes; 0.4.9 was 19.6 MB).
  Since 0.4.7 main holds:
  - the audit's runtime fixes C3 (the reader window redraws only when what it shows changes, `ReaderShownState`, the sleep countdown in `SleepTimerStatusLabel`), C4, C6, C7, C8, C9, C16, and C17;
  - the BRF fixes from the user's Life of Pi: running heads left out (keyed without their numbers), print page change lines, chapter rows as headings, title and author from the braille title page, and the English Braille, American Edition suggestion announced once;
  - the EBAE decoding fixes in the braille helper (`fix_ebae_cells`).
    All 13 "St."/"Still." places in Life of Pi read as its EPUB does (checked by the orchestrator, read-only);
  - the Reading List's cloud follow-ups (unknown sizes one at a time, books left out logged);
  - in 0.4.10: the braille code guess at import (`BrailleTableOrigin`, the Braille tab's switch, Keep This Code, kept through Replace Existing), the sort helper (C10), and `Book` in one copy-on-write box (C13, `Book.Storage`; how to add a field is in `docs/architecture/state/library-index.md`);
  - every hosted test class placed in an area of `Scripts/test/areas.conf` (a new `readers` area; `run-area.py --unassigned` says 0).
- Every merge went review, then a fix round, then often a check, then a Mac full suite on `integrate/1113` (read `run_suite.py`'s exit status, not the Executed line), then a fast-forward.
  The records are in the TODO.
- Not done, each needing the user's yes: the audit's C11, C12, C14, C15, and C19, and the cloud library's Phase 0 guards (questions in `humanQuestions/2026-11-13.md`).
- Lessons of that night, which hold for any campaign:
  - A braille rule an agent states is a claim to check: a reviewer said UEB writes 6-N and 6-Y, and the user, a braille reader, knew UEB had dropped ation and ally (BANA's UEB FAQ).
    Check rules against BANA, ICEB, or `lou_translate` on the repo's tables, and build test cells from liblouis forward, not by hand.
  - Every `make check` an agent runs needs `SIGN_APP=true`: without it `codesign` waits on the login keychain, and two agents' runs held the heavy lock for an hour each.
  - The Mac suite's exit status is the gate.
    "1 failure (0 unexpected)" is a real failure: main was fast-forwarded once on the Executed line and taken back within a minute.
  - A branch that adds a test file must commit the regenerated project: trains regenerate it, so they never notice when it's missing.
  - Write times from `date`.
    The orchestrator's log ran up to 5.5 hours ahead of the clock and told the user the reset was near when it was five hours away.
  - When the disk falls under 8 GB, clear finished worktrees and scratch at once (literal paths); it reached 2.7 GB free during measurements.
