# Team audiofmt, review round: what every fix brief shares (October 18, 2026, evening)

Two Opus reviewers read `team/audiofmt` and found fifteen problems. Each worker fixes the items its brief names. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first (the October 14 rule, samples, builds, commits, words), then this page, then your brief. This page adds to `common.md` and wins where they differ.

## One build of the team at a time, by turns
The disk is nearly full, so the team builds one at a time, in turns your lead hands out.
1. **Write first.** Write your fixes and your tests without building.
2. **Ask for a turn.** Post `ready: <slug>` to your lead: `python3 .claude/skills/agent-bbs/scripts/bbs.py post <slug> --to audiofmt-lead --tag notice --topic "ready: <slug>"`. Then wait for `go: <slug>`, by message or on the board (`bbs watch <slug> --timeout 240`, again as often as needed). Never build before it.
3. **Your turn.** Before each build, `df -h /System/Volumes/Data` must show at least 3 GB free; if not, tell your lead and wait. Run the proof below, fix what fails, then lint (`make lint-tests LINT_BASE=team/audiofmt` and `make lint-ogg LINT_BASE=team/audiofmt`).
4. **End your turn.** When your last build is done: `BBS_AGENT=<slug> python3 Scripts/test/run-area.py --clean`, then post `turn done: <slug>` to your lead. Only then write your report.
A turn takes about 20 minutes at most. If you need longer, or a second turn later, tell your lead.

## Proof that each new test fails without its fix
The orchestrator asks for a test that fails without each fix. In your turn:
1. Commit each item (its fix with its tests) as your brief says.
2. **The failing run.** Put back the base version of each existing app file your commits changed, keeping your tests: `git checkout team/audiofmt -- <each changed app file, by its literal path>`. A new app file stays; it must not break the build of the old code. Run your test classes: your new tests must fail. A test that needs an API your fix adds cannot compile against the old code: then that compile failure is its proof, but make at least one test of each item fail at run time.
3. **The passing run.** `git checkout HEAD -- <the same files>`; run your test classes again: everything passes.
Keep the failing run's `Executed` line and the names of the tests that failed, for your report. Never use `git stash`: the stash is shared with every worktree.

## Literal paths, always
Never `rm` with a shell variable anywhere in its path: not in a loop, not in a script you run. Claude Code stops such an `rm` for the user's approval, and on October 18 one waited five hours while the team stood still. For an experiment, make a new folder with a literal name in the scratchpad (`/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/<slug>-<what>`), give each output its own name, and delete nothing during the run. When you must delete, write the literal path.

## Commits
One small commit for each review item (more when your brief says so). Each message's subject says what changed; its body ends with `(review item N)` before the `Co-Authored-By` line.

## Your report (at most 15 lines)
Your branch; each commit's hash and subject; for each item, the tests that prove it and the failing run's `Executed` line with the tests that failed; your passing run's `Executed` line; every new sentence a listener hears, quoted; what you could not verify; your decisions.
