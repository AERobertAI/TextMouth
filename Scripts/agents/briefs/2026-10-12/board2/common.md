# Team board2: what every worker needs (October 12, 2026)

Team `board2`, lead `board2-lead`, team branch `team/board2`. The team changes only the message board: `.claude/skills/agent-bbs/scripts/bbs.py`, `.claude/skills/agent-bbs/tests/test_bbs.py`, and `.claude/skills/agent-bbs/SKILL.md`. Nothing in this team builds the app, so ignore everything about Xcode, build slots, and build folders.

Read `Scripts/agents/briefs/2026-10-12/teams-common.md` lines 36 to 72 only ("The worker's part", "Rules for everyone", and "The board"). This file replaces its build steps.

## Four workers edit the same three files at once
Each brief names the functions, test classes, and SKILL.md lines that are yours. Edit nothing else in those files, not even a stray blank line or a comment, so that the lead can stack the four branches without conflicts. Do not reformat or reorder code you do not change.

## The live board: never with your own copy
Other teams use the live board while you work. Your worktree's `bbs.py` is a changed copy from the moment you edit it, and **it must never touch the live board**.
- **For every live-board command** (register, task move, post, release), run this read-only copy of main's script, from your worktree root:

      python3 /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/board2-live-bbs.py

  Below, `LIVE` stands for that command. Never edit that file.
- **To try your own copy by hand,** always prefix the command with a scratch board, written as a literal path: `TEXTMOUTH_BBS_DIR=<scratchpad>/<slug>-board python3 .claude/skills/agent-bbs/scripts/bbs.py ...`. Without the prefix, your copy would open the live board.
- `<scratchpad>` is the scratchpad directory your environment names. Prefix every scratch file with your slug.

## Steps
1. **Branch.** In your worktree, `git checkout -b board2/<task> team/board2`. Your worktree starts on an old commit, so this step matters.
2. **Register, joining the team, and start your task** (your brief gives the task number):

       LIVE register <slug> --role "ONE LINE" --branch board2/<task> --team board2 --files .claude/skills/agent-bbs/scripts/bbs.py .claude/skills/agent-bbs/tests/test_bbs.py .claude/skills/agent-bbs/SKILL.md
       LIVE task move <slug> <id> working

   Other workers in your team claim the same three files, so `register` reports overlaps with them. That is expected; your brief keeps you in your own part of each file.
3. **Change and test.** Make the change with its tests, one logical change per commit. Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. After each commit: `LIVE post <slug> --to team:board2 --tag commit --topic "<hash> <subject>"`.
4. **Run the board's whole test file,** which takes about 15 seconds. Write paths literally, because the worktree guard refuses shell variables in commands that run python or git:

       TEXTMOUTH_BBS_DIR=<scratchpad>/<slug>-board python3 -m unittest discover -s .claude/skills/agent-bbs/tests > <scratchpad>/<slug>-tests.log 2>&1

   Then read the result with `tail -3 <scratchpad>/<slug>-tests.log`, or with `grep -E "^(FAIL|ERROR):|Error|Ran [0-9]+ tests|OK|FAILED" <log> | tail -20`. Before your changes the file ran 195 tests, OK.
5. **Finish.**
   - `LIVE task move <slug> <id> review --note "ONE LINE"`.
   - `LIVE post <slug> --to board2-lead --topic "done: board2/<task>"`.
   - `LIVE release <slug> --all`.
   - Reply with a report of at most 15 lines: the branch; each commit's hash and subject; the tests you added and the exact `Ran N tests ... OK` result; what you could not verify; and the decisions you made.

## Rules
- Never push, never merge, and never run git commands against another worktree or the main checkout.
- The worktree guard refuses compound git commands such as `cd … && git …`: run git plainly from your worktree root.
- Every function gets a docstring, and every non-obvious block a comment. Keep the code DRY: reuse the helpers your brief names.
- Wording is read by agents, and also by the user, who uses VoiceOver and a braille display. Pin every sentence your change prints with a test, word for word.
- No test may touch the live board. Every test uses a temporary board (the `BoardTestCase` base class sets `TEXTMOUTH_BBS_DIR`) or a temporary repository.
- Edit no `*.md` file except the SKILL.md lines your brief names.
