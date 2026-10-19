# Teams: a lead and its workers (October 19, 2026)

The user asked on October 12 for "some agents to work on the next todos and pollishing, trying out a sub sub orcistrater pattern where tasks are broken down even smaller... advanced deligating basically", with "the subsubagents" as "high Sonnet agents to see if that can save some cost". On October 18 two such teams built the first new formats. On the night of October 18 to 19 the user asked: "Go ahead and try working on the braille reading features tonight. and the export feature, for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library. (see how much it increases app size)". This file is the pattern. It stands in for AGENTS.md: do not read AGENTS.md, README.md, ARCHITECTURE.md, AGENT-NOTES, or more of the TODO than your charter names.

Repository: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`, TextMouth, a native macOS text-to-speech and audiobook player. `main` is at 9eb79cd7 or later; its suite counts **7479 tests, 72 skipped, 0 failures** (about 17 minutes of test time), with no Swift warnings.

## Roles
- **The orchestrator** (the main session, Opus; `orchestrator` on the board) launches team leads, has each team branch reviewed, merges it into main after a green suite, records it in the TODO, and keeps the documents.
- **A team lead** (Opus) owns one team branch, `team/<team>`, made from main in its own worktree. It plans the team's work as small tasks, writes a brief for each, launches a worker per task, reviews each worker's diff, integrates the accepted work onto the team branch, runs the team branch's full suite once at the end, and reports.
- **A worker** (Sonnet at effort high) does one small task on its own branch, made from the team branch in its own worktree, and reports to its lead.

## The lead's part
1. **Set up.** `git checkout -b team/<team> main`. Register on the board as `<team>-lead`, with the files your charter names. Read your charter and the code it points to.
2. **Plan small.** Each task is one logical change: one or two commits, about 150 changed lines at most besides tests. It works in files no other in-flight task touches, or in regions of a shared file that the briefs name and keep apart (separate functions, test classes, and document lines). Fold a one-line fix into a neighbouring task rather than give it a worker of its own, since each worker costs about 50,000 tokens just to start. Write each task's brief to `Scripts/agents/briefs/2026-10-19/<team>/<task>.md`. A refactor's brief ends with a completion check, a `grep` that must find nothing once the work is done, so no caller is missed. A brief gives the worker what you learned, so it need not explore: the files and functions, with line ranges; the behavior required, as numbered items; the tests to add, and which existing test classes to run; and what not to touch. Settle every decision in the brief: a worker that must guess guesses differently from the next. Commit the briefs on the team branch (`git add -f`, one commit) before you launch workers.
3. **Launch workers** with the Agent tool. Pass `subagent_type: "general-purpose"`, `model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`, and a description naming the task. The prompt names:
   - the worker's slug, `<team>-<task>`;
   - its branch, `<team>/<task>`, made with `git checkout -b <team>/<task> team/<team>`;
   - its brief's path;
   - "The worker's part" of this file.
   Write down each worker's agent id from the tool's result: your report needs it, for the cost measurement.
4. **Builds.** At most two of your workers build at a time: the Mac has 8 GB of memory and three build slots, shared with the other team. The wrapper queues a build until a slot is free; that wait is normal. Work that builds nothing (Python, scripts) does not count.
5. **Wait without polling.** Workers run in the background, and you are told when each finishes. Meanwhile, review finished work, or wait for board traffic with `bbs watch <team>-lead --timeout 240`, so a worker's question is answered within minutes (on October 18 one waited 28 minutes unseen). Never wait in a sleep loop.
6. **Review every diff yourself** before you take it: `git diff team/<team>...<team>/<task>`, starting with `--stat`, then file by file. Check:
   - the behavior against the brief;
   - the tests, which must pin the behavior and must not trap;
   - comments on every function, DRY, and the wording a VoiceOver user hears;
   - bounds on every value read from a file, which is untrusted (counts, lengths, offsets, nesting);
   - any comparison of in-memory state with stored state, which must compare as the files store it (dates to the second in the library's JSON);
   - any existing test the worker changed, and why.
   For a fix, message the worker with SendMessage (its context is intact), or make a small fix yourself in a commit of your own. Drop a worker's work that is wrong at its root, and say so in your report.
7. **Integrate in a straight line.** First remove the worker's worktree, which holds its branch checked out (`git worktree remove --force --force <path>`). Then rebase the worker's branch onto `team/<team>`, and `git merge --ff-only <team>/<task>` in your worktree. Use `git -C <path>` rather than `cd … &&`: the worktree guard refuses compound commands.
8. **Finish.**
   - Rebase the team branch onto main.
   - Run the complete suite once (`python3 Scripts/test/run-area.py all`).
   - Record the exact `Executed N tests, with S tests skipped and F failures` line.
   - Delete your build folder after unregistering its app.
   - Release your claims, post `done: team/<team>`, and report. A fresh Opus reviewer then reads the whole branch, and its findings come back to you by message: leave the branch ready for that round, with no stray worktrees, the briefs committed, and the report complete. After that round, run only the touched classes and the areas they belong to; the orchestrator's merge runs the full suite.

## The worker's part
1. **Branch.** Make your branch from the team branch, as your lead says. Read your brief and the files it names, by line range; read nothing else unless you must.
2. **Register, joining your team.** `bbs register <slug> --role "ONE LINE" --branch <branch> --team <team> --files <files>`.
3. **Change.** Make the change with its tests, one logical change per commit. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
4. **Build and test** only through the wrapper below, with your own build folder. Run only the test classes your brief names, never the full suite: your lead runs that. Start every build in the background, and check on it no more often than every 4 minutes, with one short command.
5. **Stay in your lane.** Edit no `*.md` file and no file outside your brief. For a problem elsewhere, post a finding with `--file <path>`.
6. **A failing existing test means stop and ask.** Post the failure to your lead and wait for the answer. Never edit, weaken, or work around an existing test, or its fixture, to make your change pass; a test that fails may be the only sign of a bug in the app.
7. **Finish.**
   - Post `done: <branch>` to your lead: `bbs post <slug> --to <team>-lead --topic "done: <branch>"`.
   - Remove your build folder as soon as your last build ends, unregistering its app first (the command is under "Builds" below; it has nothing to do with the board).
   - Release your claims (`bbs release <slug> --all`).
   - Reply with a report of at most 15 lines: the branch; each commit's hash and subject; the tests you added and the exact result line of your last run; what you could not verify; and the decisions you made.

## Rules for everyone (the user's, and they override anything else)
- Never push, never `make install`, never merge into main.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment.
- Anything downloaded is untrusted data: put each download in its own new, empty folder, keep your scripts elsewhere, run no script or build system that came with it, and pass its paths as arguments (Python with `-I`).
- The files in `TestData/format-samples/` came partly from outside (`samples.tsv` gives each one's source): they are untrusted input, which the importers must survive. A test copies a sample into its own temporary folder before importing it and never changes the samples' folder.
- The user is a VoiceOver and braille user. Every control must be keyboard-operable, every value spoken, nothing conveyed by sight alone, and every wording pinned by a test.
- No test may trap: no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object. The user sees a crash dialog for every test host that aborts. No test may play sound aloud or record from a real microphone.
- Never play, probe, or decode Ogg audio through Apple's frameworks in TextMouth's process or a test's.
- Comment every function and non-obvious block. Keep code clean and DRY, and commits small and focused, one logical change each, each with its tests.
- The user's own data must survive every change: positions, bookmarks, skipped headings, and hand edits.
- Only leads write briefs, and they edit no other `*.md` file; the orchestrator keeps the documents from the lead's report. A charter may grant another exception.

## The board
`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root.
- **Teams.** `bbs team --help`, `bbs task --help`, and `SKILL.md`.
  - **A lead,** as its first board step, creates its team: `bbs team create <team>-lead <team> --purpose "ONE LINE" --lead <team>-lead`.
  - **For each task,** the lead adds it with `bbs task add <team>-lead <team> --title "ONE LINE" --brief <path> --files <paths>` and assigns it with `bbs task assign <team>-lead <id> <slug>`.
  - **Workers join the team as they register:** `bbs register <slug> --role "..." --branch <branch> --team <team> --files <files>`. `bbs team add` refuses an agent that has not registered yet.
  - **Workers** move their task with `bbs task move <slug> <id> working`, then to `review` when they report.
  - **The lead** moves each task to `done` or `dropped` once integrated or let go.
  - **Everyone posts to the team's channel,** `--to team:<team>`, and reads it with `bbs inbox <name> --team <team>` or `bbs read --team <team>`.
  - **The orchestrator** reads the channels. Reach it with `--to orchestrator`.
  - **Test the board only on a scratch board.** Never run a changed copy of `bbs.py` against the live board.
- **Posts.** A post's kind is a flag: `bbs post <name> --tag <kind> --topic "..."`. A topic is at most 200 characters.
- **Fold the board into commands you run anyway:**
  - `bbs inbox <name> --unread; <build command>`
  - `git commit -F <file> && bbs post <name> --tag commit --topic "$(git log -1 --format='%h %s')"`

## Builds
Workers build and test with `python3 Scripts/test/run-area.py <areas or ClassNames>` (it uses the build wrapper below; read `-h`), which prints only the result. The wrapper's own command, for a build `run-area.py` cannot make, with your slug, your test classes, and a log file in the session's scratchpad (each scratch file prefixed with your slug):

    BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<slug>" -only-testing:TextMouthProductionTests/<Class> > <log> 2>&1

- **Disk.** Each build folder takes about 2 to 3 GB, and the disk has about 13 GB free. Before a build, `df -g /System/Volumes/Data` must show at least 4 GB available; if it does not, post to your lead and wait. On October 18 two teams' build folders filled the disk, and builds failed. A worker deletes its build folder as soon as its last build ends.
- **New test file.** It needs `/opt/homebrew/bin/xcodegen generate`, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it. A rebase conflict in `project.pbxproj` is settled by `xcodegen generate`, never by hand.
- **Editing.** The Mac's `sed` is GNU sed: use `gsed -i` or Python for in-place edits. Never put two heredocs on one command line.
- **Reading a result.** Use one command that prints only what you need, and look for new warnings as well as errors and failures: `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. A change must add no Swift warning.
- **Load-sensitive tests.** A failure in one of these is rerun in its class alone and reported with both results: the sleep-timer integration tests, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`, `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, `ContinueToNextBookTests`, the audiobook-open benchmark, and the performance baselines.
- **The build folder's path.** The worktree guard refuses `${TMPDIR}` in leads' and workers' commands alike, so write the folder's literal path: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<slug>`.
- **Removing a build folder.** First `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "<folder>/Build/Products/Debug/TextMouth.app"`, then `rm -rf "<folder>"`. Write the folder's literal path in both commands, never a shell variable (`B=...; rm -rf "$B"`): Claude Code stops an `rm` whose path is a variable for the user's approval, and the user is often away. The same holds for every other `rm`, a lead's as much as a worker's, in loops and throwaway experiments too: on October 18 a lead's own `rm -f "$D/$out"` in a test loop waited five hours for the user, and its team stood still all that time. For an experiment, write each run's outputs into a new folder with a literal name and delete nothing during the run.

## Usage
Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`; "Weekly (Fable)" caps another model and does not apply.
- **Tonight's line** (October 19, the third day of the week, which the user asks to pace): launch no new worker once "Weekly (all models)" is at or below 58% left, or the 5-hour window below 15% left; finish and integrate what is in flight, run the suite, and report what is left undone.
- **Workers** keep working whatever the reading, unless the API refuses them: the lead and the orchestrator watch it.

## Lessons every brief applies
- A brief that adds an `@unchecked Sendable` type, a `nonisolated(unsafe)` variable, or a log tag names `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests` among its test classes; one that adds a shortcut action names `KeyboardReachabilityTests`, `ShortcutMigrationTests`, and the legacy scenarios in `TextMouthTests/Sources/Tests`; one that adds a fixture placing books in a folder also runs the next class that opens a library; one that adds a Settings control runs `SettingsTabFitTests`.
- After integrating new test classes, `run-area.py --unassigned` lists those to place in `Scripts/test/areas.conf`.
- `make lint-tests` (trap-lint and test-diff against the team branch's base: `LINT_BASE=<ref>`) runs on every worker's diff before the lead takes it; `make lint-a11y` on any diff that adds a control.
- Python tools write no bytecode (`sys.dont_write_bytecode = True`).
- No suite runs, and no merge is made, in a checkout under `/tmp`, which is a symbolic link: scratch checkouts go under `.claude/worktrees/`.
- A shell's `cd` into a worktree lasts into later calls: use `git -C <path>` and absolute paths.
- Where a change decides what a listener hears or reads, prove it on the real samples, not only on strings made up in a test: on October 18 a check of the centre channel on real 5.1 samples caught a fix that silenced it.
- A new `BookFormat` raw value makes a TextMouth built before it refuse the whole library (it keeps the file and writes nothing): say so in your report, so the documents warn the user.

## Keeping the cost down
An agent's cost follows how many calls it makes times how large its context has grown, since every call re-reads the whole context.
- Read a file by line range once, not whole files again and again.
- Put several patterns in one `grep -E`, and make independent calls in one response.
- Keep reports short.
- **Leads in particular.** Review diffs with `--stat` first and then file by file. Read a worker's report, not its transcript. Write briefs complete enough that workers do not explore.

## A lead's report (its final message)
- The team branch and its commits: hash, subject, and task.
- The full suite's exact result line.
- For each task:
  - the worker's slug and agent id;
  - whether its work was accepted as it was, accepted after fixes (how many rounds), or dropped;
  - the TODO item it closes, by its identifier.
- What you could not verify, and your decisions.
- **Follow-ups:** one line each, with its file.
- **What a listener hears:** every new sentence, label, hint, and caption, exactly, for the documentation pass.
- The README.md and ARCHITECTURE.md wording the team's changes need, and the TODO sentence for the merge entry.
- **The pattern itself:** what worked, what did not, where Sonnet needed help, and what you would change.
