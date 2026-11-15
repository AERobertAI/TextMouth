# Working on TextMouth with coding agents

This file holds what every agent session must know, whether it orchestrates or works on one task.
The orchestrator's own rules are in [Orchestrating TextMouth's agents](docs/agents/orchestrator.md).

## Start here

- [`docs/agents/writing-docs.md`](docs/agents/writing-docs.md): how every page and memory file is written; follow it in any document you edit.
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
- `humanQuestions/` (in the main checkout only) holds the user's questions and answers: read its newest file before asking anything again, since an answer there is the user's answer, and put new questions in a new file.

## The user's standing rules

- Never install: the user runs `make install` themselves when told main is ready.
- Task agents never push, except to `TestBuild` through the train tools.
  Only the orchestrator pushes main and its version tags, and only at a version bump it judges a fairly stable release: a green full Mac suite on that tree, `make check` passed, and nothing private in the commits (no path under `build/`, `humanQuestions/`, or `humanReports/`).
- `github_run.py`'s workflow guard is on: a change to `.github/workflows/` or `.github/actions/` runs on `TestBuild` only after it is on GitHub's main, so it ships with a release push after an outside review.
- Nothing on this Mac may start an iPhone simulator: the iPhone tests run on GitHub, and `make typecheck-ios` needs only Xcode's SDK.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment; copy what a test needs into its own sandbox, and read its logs only for a diagnosis.
- Never search from `/` or the home folder (`find`, `mdfind`, `du`, `ls -R`): it walks the user's Downloads, Documents, and cloud drives and puts macOS privacy prompts on their screen.
- Never play, probe, or decode Ogg through Apple's frameworks in a test or an experiment: its Vorbis decoder locked up in `AVPlayer` once and took the Mac down; `make lint-ogg` flags new calls.
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
   It reads this file, its brief, and the documents the brief names.
   It registers on the board as its slug with `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <paths or 'quoted globs'>`, then runs `bbs claims` and `bbs read --last 10` for overlaps.
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

- Write merge messages and helper scripts to files: `git merge -F -` does not read standard input, and two heredocs on one command line swallow the second.
- Prefix every scratch file with your slug, or keep a subfolder named for it: all agents of a session share its scratchpad folder, and the orchestrator's files start with `orchestrator-`.
- Run a changed copy of `bbs.py` only with `TEXTMOUTH_BBS_DIR` set to a scratch folder, never against the live board.
- Give every `rm` a literal or relative path, never a variable, substitution, glob, or built path, and put the rule in every agent's prompt: a tool call that waits on a permission prompt stops its agent until the user answers.
- Before a revert, grep for each symbol the commit added: a revert also removes helpers that other code uses.
- Host a SwiftUI view whose width follows its offer and adds to it (a macOS form in the columns style did) inside a fixed frame, or measure it with `NSHostingController.sizeThatFits(in:)` and no window, or the test host ends in a crash dialog.
  Rebase an old branch before any hosted test run on this Mac, or the test host can take the user's AirPods.
  The mechanisms of both are in [The hosted-test sandbox](docs/architecture/state/hosted-test-sandbox.md).
- Check a braille rule that an agent states against BANA, ICEB, or `lou_translate` on the repo's tables, and build test cells from liblouis forward, not by hand.
- Run every `make check` with `SIGN_APP=true`: without it `codesign` waits on the login keychain while holding the heavy lock.
- Write times from `date`, never from a guess.

## Where things stand

- Main is version 0.4.10 (tag `v0.4.10`, a1214dc0, pushed to GitHub with main); `v0.4.9` is at 8918f4ee and `v0.4.8` at 82e68c0d, and the user still runs 0.4.2.
  The Release app is 18.3 MB (0.4.9 was 19.6 MB).
- Since 0.4.7 main holds:
  - the audit's runtime fixes C3 (the reader window redraws only when what it shows changes: `ReaderShownState`, `SleepTimerStatusLabel`), C4, C6 to C9, C16, and C17;
  - the BRF fixes from the user's Life of Pi, and the EBAE decoding fixes (`fix_ebae_cells` in `TextMouthBraille/main.c`);
  - the Reading List's cloud follow-ups;
  - the braille code guess at import (`BrailleTableOrigin`, the Braille tab's switch, Keep This Code), the sort helper (C10), and `Book` in one copy-on-write box (C13, `Book.Storage`; see `docs/architecture/state/library-index.md` for adding a field);
  - every hosted test class placed in an area of `Scripts/test/areas.conf` (`run-area.py --unassigned` says 0).
- Every merge went review, a fix round, often a check, a Mac full suite on an `integrate/` branch, then a fast-forward; the TODO records each.
- Not done, each needing the user's yes: the audit's C11, C12, C14, C15, and C19, and the cloud library's Phase 0 guards (`humanQuestions/2026-11-13.md`).
