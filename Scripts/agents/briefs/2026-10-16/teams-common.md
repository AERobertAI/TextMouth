# Teams: a lead and its workers (October 16, 2026)

The user asked on October 12 for "some agents to work on the next todos and pollishing, trying out a sub sub orcistrater pattern where tasks are broken down even smaller... advanced deligating basically", with "the subsubagents" as "high Sonnet agents to see if that can save some cost". On October 16 the user asked for the same pattern with Sonnet throughout: "using orcestrator with sub agents and sub sub agents (using Sonnet) to maximize the work done, and try working through the todos, building resuable testing scripts for anything you can test outside of VoiceOever". This file is the pattern. It stands in for AGENTS.md: do not read AGENTS.md, README.md, ARCHITECTURE.md, AGENT-NOTES, or more of the TODO than your charter names.

Repository: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`, TextMouth, a native macOS text-to-speech and audiobook player. `main` is at 8cfdc5bb or later; its suite counts **6310 tests, 67 skipped, 0 failures**, with no Swift warnings.

## Roles
- **The orchestrator** (the main session, Opus; `orchestrator` on the board) launches team leads, merges each team branch into main after a green suite, records it in the TODO, and keeps the documents.
- **A team lead** (Sonnet tonight, at the user's request) owns one team branch, `team/<team>`, made from main in its own worktree. It plans the team's work as small tasks, writes a brief for each, launches a worker per task, reviews each worker's diff, integrates the accepted work onto the team branch, runs the team branch's full suite once at the end, and reports.
- **A worker** (Sonnet at effort high) does one small task on its own branch, made from the team branch in its own worktree, and reports to its lead.

## The lead's part
1. **Set up.** `git checkout -b team/<team> main`. Register on the board as `<team>-lead`, with the files your charter names. Read your charter and the code it points to.
2. **Plan small.** Each task is one logical change: one or two commits, about 150 changed lines at most besides tests. It works in files no other in-flight task touches, or in regions of a shared file that the briefs name and keep apart (separate functions, test classes, and document lines). Fold a one-line fix into a neighbouring task rather than give it a worker of its own, since each worker costs about 50,000 tokens just to start. Write each task's brief to `Scripts/agents/briefs/2026-10-16/<team>/<task>.md`. A refactor's brief ends with a completion check, a `grep` that must find nothing once the work is done, so no caller is missed. A verifier's brief gives it the items one per line, split by a script, never long lines of several items. A brief gives the worker what you learned, so it need not explore: the files and functions, with line ranges; the behavior required, as numbered items; the tests to add, and which existing test classes to run; and what not to touch. Commit the briefs on the team branch (`git add -f`, one commit) before you launch workers.
3. **Launch workers** with the Agent tool. Pass `subagent_type: "general-purpose"`, `model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`, and a description naming the task. The prompt names:
   - the worker's slug, `<team>-<task>`;
   - its branch, `<team>/<task>`, made with `git checkout -b <team>/<task> team/<team>`;
   - its brief's path;
   - "The worker's part" of this file.
   Write down each worker's agent id from the tool's result: your report needs it, for the cost measurement.
4. **Builds.** At most two of your workers build at a time: the Mac has 8 GB of memory and three build slots, shared with the other teams. The wrapper queues a build until a slot is free; that wait is normal. Work that builds nothing (Python, scripts) does not count.
5. **Wait without polling.** Workers run in the background, and you are told when each finishes. Meanwhile, review finished work, or wait for board traffic with `bbs watch <team>-lead --timeout 240`. Never wait in a sleep loop.
6. **Review every diff yourself** before you take it: `git diff team/<team>...<team>/<task>`, starting with `--stat`, then file by file. Check:
   - the behavior against the brief;
   - the tests, which must pin the behavior and must not trap;
   - comments on every function, DRY, and the wording a VoiceOver user hears;
   - any comparison of in-memory state with stored state, which must compare as the files store it (dates to the second in the library's JSON);
   - any existing test the worker changed, and why.
   For a fix, message the worker with SendMessage (its context is intact), or make a small fix yourself in a commit of your own. Drop a worker's work that is wrong at its root, and say so in your report.
7. **Integrate in a straight line.** First remove the worker's worktree, which holds its branch checked out (`git worktree remove --force --force <path>`). Then rebase the worker's branch onto `team/<team>`, and `git merge --ff-only <team>/<task>` in your worktree. Use `git -C <path>` rather than `cd … &&`: the worktree guard refuses compound commands.
8. **Finish.**
   - Rebase the team branch onto main.
   - Run the complete suite once.
   - Record the exact `Executed N tests, with S tests skipped and F failures` line.
   - Delete your build folder after unregistering its app.
   - Release your claims, post `done: team/<team>`, and report.

## The worker's part
1. **Branch.** Make your branch from the team branch, as your lead says. Read your brief and the files it names, by line range; read nothing else unless you must.
2. **Register, joining your team.** `bbs register <slug> --role "ONE LINE" --branch <branch> --team <team> --files <files>`.
3. **Change.** Make the change with its tests, one logical change per commit. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
4. **Build and test** only through the wrapper below, with your own build folder. Run only the test classes your brief names, never the full suite: your lead runs that. Start every build in the background, and check on it no more often than every 4 minutes, with one short command.
5. **Stay in your lane.** Edit no `*.md` file and no file outside your brief. For a problem elsewhere, post a finding with `--file <path>`.
6. **A failing existing test means stop and ask.** Post the failure to your lead and wait for the answer. Never edit, weaken, or work around an existing test, or its fixture, to make your change pass; a test that fails may be the only sign of a bug in the app.
7. **Finish.**
   - Post `done: <branch>` to your lead: `bbs post <slug> --to <team>-lead --topic "done: <branch>"`.
   - Remove your build folder, unregistering its app first (the command is under "Builds" below; it has nothing to do with the board).
   - Release your claims (`bbs release <slug> --all`).
   - Reply with a report of at most 15 lines: the branch; each commit's hash and subject; the tests you added and the exact result line of your last run; what you could not verify; and the decisions you made.

## Rules for everyone (the user's, and they override anything else)
- Never push, never `make install`, never merge into main.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment.
- The user is a VoiceOver and braille user. Every control must be keyboard-operable, every value spoken, nothing conveyed by sight alone, and every wording pinned by a test.
- No test may trap: no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object. The user sees a crash dialog for every test host that aborts. No test may play sound aloud or record from a real microphone.
- Comment every function and non-obvious block. Keep code clean and DRY, and commits small and focused, one logical change each, each with its tests.
- The user's own data must survive every change: positions, bookmarks, skipped headings, and hand edits.
- Only leads write briefs, and they edit no other `*.md` file; the orchestrator keeps the documents from the lead's report. A charter may grant another exception.

## The board
`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root.
- **Teams.** The board has had teams since the board team's merge on October 12: `bbs team --help`, `bbs task --help`, and `SKILL.md`.
  - **A lead,** as its first board step, creates its team: `bbs team create <team>-lead <team> --purpose "ONE LINE" --lead <team>-lead`.
  - **For each task,** the lead adds it with `bbs task add <team>-lead <team> --title "ONE LINE" --brief <path> --files <paths>` and assigns it with `bbs task assign <team>-lead <id> <slug>`.
  - **Workers join the team as they register:** `bbs register <slug> --role "..." --branch <branch> --team <team> --files <files>`. `bbs team add` refuses an agent that has not registered yet.
  - **Workers** move their task with `bbs task move <slug> <id> working`, then to `review` when they report.
  - **The lead** moves each task to `done` or `dropped` once integrated or let go.
  - **Everyone posts to the team's channel,** `--to team:<team>`, and reads it with `bbs inbox <name> --team <team>` or `bbs read --team <team>`.
  - **The orchestrator** reads the channels. Reach it with `--to orchestrator`.
  - **Test the board only on a scratch board.** Never run a changed copy of `bbs.py` against the live board: point `TEXTMOUTH_BBS_DIR` at a scratch folder first. Since the board2 merge, the script refuses the live board when main has never had its contents. A team that changes `bbs.py` therefore uses main's copy for the live board: `git show main:.claude/skills/agent-bbs/scripts/bbs.py` saved to a read-only scratch file.
- **Posts.** A post's kind is a flag: `bbs post <name> --tag <kind> --topic "..."`. A topic is at most 200 characters.
- **Fold the board into commands you run anyway:**
  - `bbs inbox <name> --unread; <build command>`
  - `git commit -F <file> && bbs post <name> --tag commit --topic "$(git log -1 --format='%h %s')"`

## Builds
Use this command, with your slug, your test classes, and a log file in the session's scratchpad (each scratch file prefixed with your slug). `-jobs 4` holds a build's peak memory to about 1.9 GB instead of 2.6 GB, at 13 seconds' cost (measured October 12):

    BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" -only-testing:TextMouthProductionTests/<Class> > <log> 2>&1

- **New test file.** It needs `/opt/homebrew/bin/xcodegen generate`, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it.
- **Editing.** The Mac's `sed` is GNU sed: use `gsed -i` or Python for in-place edits. Never put two heredocs on one command line.
- **Reading a result.** Use one command that prints only what you need, and look for new warnings as well as errors and failures: `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. A change must add no Swift warning.
- **Load-sensitive tests.** A failure in one of these is rerun in its class alone and reported with both results:
  - the sleep-timer integration tests
  - `BookmarkKeyboardAccessTests`
  - `StorageGenerationMoveTests`
  - `BookSearchModelTests.testCancelledSearchPublishesNothing`
  - `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`
  - the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`
  - `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`
  - the audiobook-open benchmark, and the performance baselines
- **The build folder's path.** The worktree guard refuses `${TMPDIR}` in leads' and workers' commands alike, so write the folder's literal path: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<slug>`.
- **Removing a build folder.** First `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "<folder>/Build/Products/Debug/TextMouth.app"`, then `rm -rf "<folder>"`.

## Usage
Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`. "Weekly (Fable)" caps another model: ignore it.
- **Tonight the user overrode the usage rule.** It is the night before the weekly reset (Saturday 8:00 a.m. Eastern), and the user said to "max it out": keep working, and keep launching workers, until the API refuses you, whatever the reading says. Do not stop at a "low" or "critical" reading.
- **Commit early.** Since the limit may cut anyone off mid-task, commit each green step at once; work on a branch survives and is resumed after the reset.
- **Workers.** Say in each worker's launch prompt that the usage rule is overridden tonight and the Fable window does not apply.

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
  - the TODO item it closes, by its identifier (such as REV12's finding 3 or a follow-up's `#number`).
- What you could not verify, and your decisions.
- **Follow-ups:** one line each, with its file.
- The README.md and ARCHITECTURE.md wording the team's changes need, and the TODO sentence for the merge entry.
- **The pattern itself:** what worked, what did not, where Sonnet needed help, and what you would change.
