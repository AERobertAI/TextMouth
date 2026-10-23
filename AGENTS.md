# Working on TextMouth with coding agents

This file is for a coding-agent session that starts cold: an orchestrator that runs several task agents at once, and the task agents themselves. It says where the project's state lives, what the user has standing rules about, how a task agent must work, and how the orchestrator merges and records. README.md is the index of the documentation, whose pages are in docs/: docs/user explains the app to its user, docs/developer how to build and test it, and ARCHITECTURE.md, the index of docs/architecture, explains the code. None repeats what is here.

## Start here

- `README.md`: the index of the documentation in `docs/`. `docs/user/` holds a page for each part of the app, for the person using it. `docs/developer/building.md` holds what you need, the make targets, and the make check gate; `docs/developer/testing.md` the hosted suite, the performance baselines, and the cloud-drive tests. `docs/agents/working-with-agents.md` introduces the message board, and `docs/agents/history.md` keeps the status of earlier campaigns.
- `ARCHITECTURE.md`: the index of `docs/architecture/`: the parts of the app, launch, who owns each kind of state (a page for each, in `docs/architecture/state/`), the reading walkthrough, the shared helpers, and the duplication left in place. Read only the pages your task touches, and keep them true after every merge.
- `TODO-2026-09-04.md`: the record. Every merge gets a `- [x]` entry before the paragraph that begins `**Open follow-ups noted by the September 28 agents**`, a sentence with the suite's exact counts appended to the long verification paragraph (search for the latest "After the … merge: **N tests, S skipped, 0 failures**"), and open items go into the paragraph that begins `**Open follow-ups noted on October 3 afternoon and evening**`. Its "Feature requests (October 3)" section holds FR01 to FR05; its "Performance review (October 3)" section holds PERF01 to PERF33.
- The research documents, each written before a feature was built and ending in the user's answered questions: `CLOUD-STORAGE-RESEARCH-2026-10-03.md` with `CLOUD-STORAGE-PLAN-2026-10-03.md` and `CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md`, `RSS-READER-RESEARCH-2026-10-03.md`, `AUDIO-RECORDING-EDITOR-RESEARCH-2026-10-03.md`, `TRANSCRIPTION-RESEARCH-2026-10-03.md`, `TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md`, `FEED-ITEMS-RESEARCH-2026-10-07.md` with `FEED-ITEMS-ADDENDUM-2026-10-07.md` (FR11), `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` (FR12), `TEXT-ANCHORS-RESEARCH-2026-10-10.md` (T06), and `END-AND-JUMP-RESEARCH-2026-10-10.md` (P07 and P08). Older notes: `CACHE-UPDATES-2026-09-09.md`, `EPUB-HEADINGS-FIX-2026-09-08.md`, `FEATURE_IDEAS0509.md`, `TODO-2026-07-12.md`.
- `AGENT-NOTES-2026-10-04.md`: what each agent of the September 28 to October 4 campaign left unverified or undone, in its own words, with the documentation wording that was still to be applied. Read it before a documentation pass.
- `.claude/skills/agent-bbs/`: the message board the agents coordinate through (`SKILL.md` is the reference; `scripts/bbs.py` is the command; `scripts/build-slot-with-bbs.sh` is the build wrapper). It was used for every task since October 2: well over a thousand messages by October 4.
- `Scripts/agents/`: `merge-chain.sh` (merge a branch into main and run the suite) and `extract-report.py` (print a subagent transcript's final report).
- `*.md` is gitignored except README.md, AGENTS.md, ARCHITECTURE.md, CLAUDE.md, and the pages under `docs/`: stage any other Markdown file (the TODO, AGENT-NOTES, the research documents, the briefs) with `git add -f`.
- `humanQuestions/` (gitignored, in the main checkout only, so agents' worktrees do not have it): the questions put to the user and their answers, one Markdown file per session or batch, named by date and part (`2026-10-07-evening.md`). Read the newest files before asking the user anything; an answer there is the user's answer.

## The user's standing rules

- Never push, and never install: the user pushes main and runs `make install` themselves when told main is ready.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment; copy what a test needs into its own sandbox. Reading its logs for a diagnosis is fine.
- Merges into `main` happen only after the full hosted suite is green on the merged tree, as non-squash merges (`git merge --no-ff`), which the user authorized for the orchestrator; the project `CLAUDE.md` otherwise forbids merging. Every merge is recorded in the TODO and described in the documentation (the pages under docs/, indexed by README.md and ARCHITECTURE.md) by a documentation pass.
- Small, focused commits, each with a test; comments on every function and non-obvious block; Markdown for every document; a VoiceOver and braille user first: every control keyboard-operable, every value spoken, nothing conveyed by sight alone.
- The user sees a macOS crash dialog for every test host that aborts, so no test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object), and no test may play sound aloud or record from a real microphone without an opt-in environment variable.
- Only TextMouth's own caches may be cleared; other apps' caches and the user's Trash are theirs.
- The system icon cache (`/Library/Caches/com.apple.iconservices.store`, root-only, invisible to `du`) grows about 23 MB with every build-and-launch of the test host and only the user can purge it: check `stat -f %l /Library/Caches/com.apple.iconservices.store` (entries plus two) at each merge and tell the user when it passes 10,000; before deleting any build folder run `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`; batch targeted test runs into fewer launches.
- The usage rule in the user's global instructions (wrap up when a limit is nearly spent) can be overridden by the user for a day; when it is, agents keep working until the API refuses them, and unmerged branches wait on their worktrees for the reset. The user set that override as standing for the night before the weekly reset (Saturdays at 8:00 a.m. Eastern; October 10, 2026: "please don't warry about the weekly reset and have a full set of agents going and work until the limit runs out, everything can just be resumed without issue in the new week... and remember this for Friday nights / Saturday mornings before the usage resets"): on a Friday night or Saturday morning keep three builders and the non-building agents going until the limit runs out, tell every agent so in its launch message, and keep a background task that exits after the reset so the orchestrator is re-invoked to resume agents that were cut off.

## How a task agent works

The orchestrator launches each agent in its own git worktree under `.claude/worktrees/` with a brief: the branch name, a task slug, the regions to avoid because other agents are editing them, the required behavior as numbered items with one commit each, the tests each item needs, the baseline test count on main, and the report format. The agent:

1. Creates its branch from `main` (a worktree can start on an older commit; branch from `main` explicitly), reads this file, its brief, and the documents the brief names, and registers on the board as its slug: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <paths or 'quoted globs'>`, then `bbs claims` and `bbs read --last 10` for overlaps. `bbs protocol` prints the full rules.
2. Reads its inbox before every build, every commit, and its report (`bbs inbox <slug> --unread`); posts a `build` notice before a full suite, a `commit` notice after each commit (`--topic "$(git log -1 --format='%h %s')"`), a `finding` with `--file <path>` for a problem in files it does not own (never fixing them), a `question` to another agent when a decision touches that agent's work, and `done: <branch>` with `bbs release <slug> --all` at the end. Posts are short; the board's topic limit is 200 characters.
3. Builds and tests only through the wrapper, one build of its own at a time, with a build folder of its own outside the repository: `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > log 2>&1`. `-jobs 4` holds a clean build's peak memory to about 1.9 GB, against 2.6 GB at Xcode's default of eight jobs, for 13 seconds more (69 to 82 seconds, measured October 12, 2026; compiling is about a minute of a full run, the tests about eleven). The wrapper holds one of three machine-wide slots (the Mac has 8 GB of memory) under `/tmp/textmouth-build-slots` (or `BUILD_SLOT_ROOT`). While iterating it adds `-only-testing:TextMouthProductionTests/<Class>`, several classes per run. A full run compiles the app and takes seven to eight minutes; a new test file needs `xcodegen generate` and the committed `project.pbxproj`. Hosted tests run inside the real app against a sandbox under the temporary directory and never join the system's media session.
4. Commits one logical change at a time, each message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (or the attribution the session's own instructions give), edits no `*.md` file (the orchestrator maintains the docs from the agent's report), and leaves files outside its task alone except for a hook its brief names.
5. Before reporting: rebases onto `main` (keeping both sides of adjacent-line conflicts, which are common in `ConfigService`, `SettingsViewModel`, `MenuCommands`, `AppDelegate.applicationShouldTerminate`, and the config test fixtures), runs the complete suite once and records the exact `Executed N tests, with S tests skipped and F failures` line, keeps `make check` in mind when the Release build or the app's size changes, deletes its build folder after unregistering its app, and releases its claims.
6. Reports: the branch; the commits with hashes and subjects; the files changed; the suite's exact result; what it could not verify; its decisions and assumptions; findings posted on the board; and the documentation wording its changes need, naming the page under docs/ each sentence belongs on, which the orchestrator or a documentation agent applies.

## How the orchestrator works

- **Task agents run on Opus, never on the orchestrator's own model.** Every launch passes `model: "opus"` (with `subagent_type: "general-purpose"` and `isolation: "worktree"`); an agent launched without a model override inherits the orchestrator's model, which on October 6 and 7, 2026 put thirteen task agents on Fable and spent the weekly Fable window (only the four read-only sheet sweeps of October 6 ran on Opus). The orchestrator, on Fable, writes the briefs, reads each report and diff, decides, merges, and records; it uses a Fable agent only when the user asks for one. Briefs are kept in `Scripts/agents/briefs/<date>/` (stage with `git add -f`), never only in the session's scratch folder, so the next session can launch from them. The orchestrator itself may run on Opus too (it did on the evening of October 7, 2026); the launches still name the model. The usage script's `binding` window can then be a weekly cap scoped to one model, such as "Weekly (Fable)", which Opus work does not count: read only the unscoped windows ("5-hour session", "Weekly (all models)"), watch them with `Scripts/agents/usage-watch-unscoped.py <left%>` as a background task, and say in every launch message that the scoped window does not apply, or an agent following the usage rule stops at once.
- One brief per task, written to `Scripts/agents/briefs/<date>/` and pointed at from the launch message; the user's decisions quoted in the brief in their own words; waves of three to five agents whose file regions do not overlap, with a shared contract or a first "core" branch when they must share types.
- After an agent reports: write the merge message to a file, note the agent's unverified items and its documentation wording where the next documentation pass will find them (`AGENT-NOTES-2026-10-04.md` is the current such file), then `Scripts/agents/merge-chain.sh <branch>:<message-file>` in the background; on a green suite, record the merge in the TODO with `Scripts/agents/record-merge.py` (the three edits named under "Start here"; `--note` in place of `--counts` for a merge that ran no suite, `--tick FR09 --hash <merge>` to tick an entry), commit the TODO, remove the agent's worktree (`git worktree remove --force --force` and `git worktree prune`), unregister and delete `build/DerivedData-main` when the disk is tight, and post `merged: <branch>` on the board with the new counts so the other agents rebase. A suite that fails only in a load-sensitive test (the sleep-timer integration tests, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`, the resume-data test `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, the audiobook-open benchmark, and the performance baselines, which skip while the Mac is busy) is rerun on that class alone before the merge stands.
- Questions for the user go into a new file in `humanQuestions/` for each session or batch, so the user can answer while away and the answers are kept: each question numbered, with its context in a sentence or two, a recommended answer, and an `Answer:` line for the user; an optional "Answer for the whole section:" line; and an "Answered this session" section quoting the answers already given in chat. Say in chat which file holds new questions. When acting on an answer, record the decision in the TODO with the user's words, as before.
- A documentation pass is its own agent (no build) that edits only the documentation (README.md, ARCHITECTURE.md, and the pages under docs/) from the merged code and the agents' wording, one commit per documented branch; it is merged without a suite as a Markdown-only merge and recorded in the TODO with a sentence.
- **The version.** The user's rule (October 23, 2026) is one bump for each day on which main gains bug fixes or small backward-compatible features. After the day's last merge, and before the user's next install, run `make bump-patch`; run `make bump-minor` instead when that day holds a change that is not backward compatible (an older TextMouth cannot open the library, every book is read again, a stored format changes, or a setting, shortcut, or file is removed or renamed). Commit the bump on its own, add the day's dated section to the top of `docs/user/changelog.md` with one plain sentence per change (a MINOR section first says what an older TextMouth can no longer do with the library), and record the bump in the TODO. MAJOR stays 0 until the user calls TextMouth released. Versions in `docs/developer/building.md` has the rules and the cases they leave open.
- Two branches that each pass can fail together; the suite after each merge on the merged tree is what counts. A branch started before another merged must rebase before its final suite.
- The orchestrator keeps its own memory of the campaign (the harness's memory directory) and tells the user, in plain words, what landed, what is unverified, and what decisions are theirs.

## Teams (since October 12, 2026)

For a wave of small tasks, the orchestrator can launch team leads in place of task agents. The user asked for it on October 12 ("a sub sub orcistrater pattern where tasks are broken down even smaller... the subsubagents could be high Sonnet agents to see if that can save some cost").
- **How a team works.** A lead (Opus) owns a team branch `team/<team>`. It breaks its charter into tasks of one or two commits, writes a brief for each, and launches a worker per task with the Agent tool (`model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`): agents can launch agents. It reviews every diff, integrates the accepted work in a straight line, runs the full suite once, and reports. The orchestrator merges the team branch like any other.
- **The briefs.** The pattern, the rules, and the report format are in `Scripts/agents/briefs/2026-10-12/teams-common.md`; each team has a charter beside it (`team-board.md`, `team-polish.md`, `team-t6d.md`).
- **The board.** It has teams, channels addressed `team:NAME`, and task lists (`SKILL.md`).
- **What it cost** on October 12, by `Scripts/agents/agent-cost.py`, which prices each call by its model (Sonnet 5.5 at half Opus 5.5's prices):
  - The board team (24 commits) and the polish team (eight fixes) cost about 0.7 and 0.6 weekly points.
  - Each lead cost about 0.5; each Sonnet worker cost 0.01 to 0.03, its context staying under 100,000 tokens.
  - A single Opus fix agent that day cost 1.56.
  - Workers were accepted as written 15 times in 16, when their briefs gave exact line ranges, the mechanism, and the tests.
  - A lead's growing context is the team's largest cost.

## Lessons that cost time

- `git merge -F -` does not read standard input; write merge messages to files. Two heredocs on one command line swallow the second; write helper scripts to files first.
- Every agent of one session shares the session's scratchpad folder: on October 9, 2026 one agent's commit-message files were overwritten by another's after use. Each agent prefixes its scratch files with its slug (or keeps a subfolder named for it), and the orchestrator's own start with `orchestrator-`.
- Agents can stall with "no progress for 600s"; a message to the agent's id resumes it with its context intact, and its branch keeps its commits. A background suite stopped at its time limit must be rerun.
- An agent that follows the usage rule stops itself at a "critical" reading; say in the launch message when the user has overridden it.
- Keep two gigabytes free before a merge suite: the archive-import tests refuse to run under the app's one-gigabyte reserve.
- A hosted SwiftUI view whose width outgrows the width offered (a macOS form in the columns style did) makes its window chase it until AppKit raises "more Update Constraints in Window passes than there are views in the window" and the test host ends with a crash dialog the user sees (twice on October 10, 2026). Host such views inside a fixed frame, or measure them with `NSHostingController.sizeThatFits(in:)` and no window.
- An agent's worktree (`isolation: "worktree"`) starts at origin/main, which can be far behind local main (1,081 commits on October 12, 2026): every brief has its agent make its branch from local main or a team branch, by name.
- A changed copy of `bbs.py` must never run against the live board: one worker did on October 12, which created the new tables early (harmlessly). Point `TEXTMOUTH_BBS_DIR` at a scratch folder first.
- A test host that joins the system's media session takes the user's AirPods; it never does now, but a branch older than that fix still can until it rebases.
- A tool call that waits on a permission prompt stops its agent until the user answers, and the user may be away. Claude Code asks before an `rm` through a shell variable: on October 18, 2026 a team lead's `rm -f "$D/$out"` in a throwaway test loop waited five hours while its team stood still. Every `rm`, in a brief or the orchestrator's own commands, takes literal paths. While agents work, the orchestrator runs `python3 -I Scripts/agents/stall-watch.py --subagents ~/.claude/projects/<project folder>/<session id>/subagents` as a background task; it exits naming any agent whose tool call has waited fifteen minutes for its result.

## Where things stood on October 21, 2026

**October 21.** The user asked for three things: fix the failing test ("send a team to see if its a real problem"), carry text formatting through braille, and pages across formats as a navigation unit, "the feature set implemented first today". Today's line was 30% of the week left. Merged into main:
- **`fix/reader-load-race` (825a3f23).** The race was real: a book moved while a reader opened it was called damaged. A moving package is now noted, and the reader waits and reloads, in cloud libraries too.
- **`braille/emphasis` (b4ca969e).** Helper protocol 2 carries emphasis both ways where liblouis reads it back: UEB, but not EBAE or most of this Mac's tables.
- **`team/pages` (77e798a0).**
  - A `<!-- page: LABEL -->` marker in content.md.
  - Page as a navigation unit, with Next Page, Previous Page, and Go to Page…, and the page on the reader screen and in Where Am I?.
  - Pages for EPUB, PDF, DOCX, DAISY text, and textutil's formats.
  - B12 (a finished Edit Text change is kept by automatic re-reads) and B13 (textutil's joined words).
  - **PG09's launch re-read of existing books** was merged switched off, since its Opus review found it unsafe for the live library.
- **`pages/pg16` (5f38016b).** It is now safe and on: a byte-for-byte compare, a stopped batch recognised, and a differing book with no edit on record copied (`content.md.edited-<UTC>`) before it gains pages. Two Opus reviews.
- **`release/version` (0587b7c4).** Version 0.2.0, `Scripts/set-version.sh` and `make set-version`, the beta procedure ("Versions" in building.md), and the user's What's new page (renamed the changelog, `docs/user/changelog.md`, on October 23).
- **Research and documentation:** `research/pages` (3c7d43b1), and the documentation pass `docs/oct21` (5c8a2a07).

**October 19 and 20.** On October 19 the user asked: "Go ahead and try working on the braille reading features tonight. and the export feature, for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library. (see how much it increases app size)". Two teams worked on it, each an Opus lead with Sonnet workers (`Scripts/agents/briefs/2026-10-19/`), and fresh Opus reviewers read every branch before its merge. Merged into main:
- `team/export` (0db62a38): FMT18 and FMT19. The Export dialog's Convert to picker offers Markdown, HTML, RTF, and Word 97-2003. One swift-markdown walker of content.md feeds every writer. Every exported file is made in a scratch folder and moved in with an exclusive rename. 12 review findings were dealt with.
- `team/braille` (3996434d): FMT20, FMT21, and FMT22.
  - liblouis 3.39.0 runs in the TextMouthBraille helper, with four English tables and a Braille tab.
  - TextMouth reads BRF, BRL, and PEF, and writes BRF and PEF from Export.
  - 26 review findings over two rounds were fixed. The app grew about 0.6 MB, to about 19.75 MB.
- `team/mactables` (b5fffa42, then e7461fe1). A Language pop-up offers this Mac's VoiceOver liblouis tables (3.34.0, read in place), each measured and checked before first use, beside the built-in English ones. 16 findings over two reviews were dealt with.
- Documentation passes: `docs/oct19` (c77c9cf4), `docs/oct19b` (bc5ef365), and `docs/oct20` (077b4e1e).

**State at the end:**
- **Main's suite:** **8230 tests, 75 skipped, 0 failures**, about 18 minutes of test time. The app's version is 0.2.0.
- **Older builds:** a TextMouth built before the braille merge cannot open a library that holds a braille book.
- **Questions:**
  - `humanQuestions/2026-10-21.md`, about pages, all built with their recommended answers;
  - `2026-10-19.md`, whose questions 1 to 4 are answered or built.
- **Pending with the user:** the push and install, the October 18 questions, and the rm-hook offer.
- **The next candidates:**
  - at the user's first launch of 0.2.0, read the debug log's `PAGES_UPGRADE_SUMMARY`; then PG12 (braille pages);
  - the EBAE and UEB emphasis reading passes;
  - FMT43 (speech to audio in Export);
  - the TODO's pages and race follow-ups.

**Lessons of October 21:**
- **A review of the whole branch is worth its cost for anything that rewrites the live library.** The pages review found the launch re-read unsafe (heading-only edits invisible to its check, kept books unprotected afterwards, an interrupted batch turned into false edits), and switching it off let the rest ship.
- **A fix to a shared writer needs the golden and heading-annotation classes in its targeted run.** pagesfix's marker change passed 388 tests and failed three others at the merge, and merge-chain had already committed the merge. main was reset to its parent (local and unpushed), and the branch was fixed and merged again.
- **Disk.** It hit 0 GB at 04:44, with six workers and two other agents building on about 6 GB, and every shell call failed. Run one build at a time when under 10 GB free, and delete build/DerivedData-main right after each merge suite: an idle one blocked the pages team for 45 minutes.
- **Untracked fixtures.** TestData zips that only the main checkout has (the DAISY audio books, the transcription fixtures) are missing from worktrees, so goldens that read them are first checked at the merge.
- **merge-chain** must be started with the Bash tool's background mode. A shell `&` worked once, but gave no notice when it ended.

**Lessons of October 19 and 20:**
- **A login expiry** stops every agent and watcher silently; the usage monitor exits with "AUTH PROBLEM". After the user logs in, a SendMessage to each agent id resumes it, and workers came back with their uncommitted work intact.
- **A restart of the user's Claude Code session** makes the old session's agents unresumable ("No transcript found"), and the session's scratchpad goes with it. Agents should therefore commit small and often. The orchestrator keeps its working files in the repository's gitignored `build/orchestrator/`, and a fresh agent finishes from the branches.
- **Review fix rounds earned their own reviews:**
  - the braille round's heading fix split multi-line titles on real books (98 of 233 Pride and Prejudice titles);
  - one mactables fix failed English exports of text holding braille characters;
  - another dropped five languages.

  Have fix rounds measure on real samples, and review them before or right after the merge.
- **Libraries' success codes are not proof.** liblouis reports success when its output fills on an escape, so check the room left. A check run shorter than the watchdog's poll proves nothing about a table's memory.
- **Strictness has a cost.** A strict up-front check can cost more than it saves: refusing every table that writes @ in eight dots would have cost 19 languages, while refusing each book by name loses nothing silently.
- **A pre-merge full suite** in the lead's worktree, run while the review runs, finds full-suite-only failures early. Run in a worktree, it skips three TranscriptionFixtureTests, whose TestData zips are untracked.
- **XcodeGen 2.45.3** orders copy-files phases differently on each run. merge-chain then regenerates and commits the project, which is harmless.
- **Pacing.** On October 20 the user, seeing their usage page on track, approved of the pacing and raised the day's line to 55% used.

**Lessons of October 18:**
- **The Opus review of a whole team branch paid for itself:** in each branch it found serious bugs that the team's own tests had passed.
- **Measure on real samples** where a fix changes what a listener hears.
- **Disk:** each team builds one worker at a time, a worker deletes its build folder after its last build, and a merge suite starts only with 3 GB free.
- **Messages:** a message sent with SendMessage reaches an agent at its next tool call; a question on the board can go unseen.

**Lessons of the October 16 and 17 Sonnet teams:**
- Sonnet leads did as well as Opus ones at these brief sizes.
- **Name the policy tests in a brief:**
  - a brief that adds an `@unchecked Sendable` type, a `nonisolated(unsafe)` variable, or a log tag names `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests`;
  - one that adds a shortcut action names the legacy scenarios and `KeyboardReachabilityTests`;
  - one that adds a field to `Book` names `ContentAnalysisMergeTests`.
- Workers build with `python3 Scripts/test/run-area.py`. A rebase conflict in `project.pbxproj` is settled by `xcodegen generate`, and new classes are placed in `Scripts/test/areas.conf` (`--unassigned`).
- Two conflicting team branches are merged in a scratch worktree, and main is fast-forwarded once green.
- Three teams that build, plus agents that do not, is the ceiling for the build slots.
