# Task `docs`: SKILL.md, and the protocol's team etiquette

Worker `board-docs`, on branch `board/docs` from `team/board`. Read `common.md` and `design.md` beside this file first.

**You may edit `.claude/skills/agent-bbs/SKILL.md`.** The team's charter makes it the one `*.md` file the team may change. Edit no other `*.md` file. Besides SKILL.md you change only `SkillDocumentTests` in `tests/test_bbs.py`.

## What to document
Every command and option the team added. Read their help rather than the code:

    python3 -c 'import subprocess, sys; [subprocess.run([sys.executable, ".claude/skills/agent-bbs/scripts/bbs.py", *c.split(), "--help"]) for c in ["team create", "team add", "team remove", "teams", "task add", "task assign", "task move", "tasks", "register", "post", "read", "inbox", "watch", "purge", "reset"]]'

(`--help` needs no board. The shell is zsh, which does not split `$c` into words, so a shell loop would pass "team create" as one argument.) `design.md` gives the rules behind them. Check anything you are unsure of by running the commands against a scratch board, never the live one.

## SKILL.md now
Read it whole once; it is 91 lines. Lines 79-91 hold the protocol, between the `<!-- protocol:begin -->` and `<!-- protocol:end -->` markers, which `bbs protocol` prints for agent briefs. Keep its style:
- short plain sentences;
- one bullet per command, starting with its synopsis in backticks;
- examples as indented code blocks;
- no tables.

## Changes
1. **The front matter.** The `description` also says the board lets agents form teams, talk in a team's channel, and keep a team's task list. It must stay one line with no ": " (colon and space) anywhere: a test checks it. Writing `team:TEAM` is fine.
2. **The opening paragraph** says, in a sentence or two, that agents can work in teams, each with a lead, a channel, and a task list.
3. **Names** (the paragraph under "## Commands"). Team names follow the same rule as agent names. A team is addressed `team:NAME`, so a team and an agent never clash, and neither does `all`.
4. **`### Agents`.** `register` gains `[--team TEAM ...]`: it joins teams that exist.
5. **A new `### Teams`**, after `### Claims`, covering:
   - `team create`, `team add`, `team remove`, and `teams [TEAM]`;
   - what a lead is, and that the lead is not counted among the members;
   - who a team's channel reaches: the lead and every member, a member from when it joined;
   - that every change to a team posts a line to its channel, so the channel is the team's history;
   - why `team:` (design.md, "Why `team:`"), in two sentences at most.
6. **`### Messages`.**
   - `post --to` accepts `team:TEAM`.
   - A reply stays in its message's channel, with the two refusals.
   - The tags include `task`.
   - `read`, `inbox`, and `watch` take `--team TEAM`.
   - The inbox paragraph names channel posts among the messages that concern you.
7. **A new `### Tasks`**, after `### Messages`, covering:
   - `task add`, `task assign`, `task move`, and `tasks`;
   - the states in order, and what each means;
   - the rules: `open` clears the assignee; `assigned`, `working`, and `review` need one; the same state again posts a progress note;
   - that an assignee may register later;
   - that each change posts a `task` line to the team's channel.
   Give one example of a lead adding and assigning a task, and one of a worker moving it to `review` with a note.
8. **`### Housekeeping`.**
   - `purge` also deletes teams that were created before the cutoff and have nothing newer in their channel, with their members and tasks.
   - `reset` also deletes every team and task.
9. **`### Where the board lives`** gains a short paragraph on compatibility:
   - the teams tables are additions that newer copies create as needed, and the layout version stays 1;
   - older copies of the script keep working on the same board, but they cannot post to a team, and their inbox does not show channel posts;
   - so work in a team needs this version of the script.
10. **The protocol** gains a step 8, **In a team**, with three duties in a sentence each:
    - a worker joins with `--team TEAM` when it registers, posts to `team:TEAM` rather than to all, and keeps its own task's state current (`bbs task move NAME ID working`, then `review` with a note);
    - a lead creates the team, hands out work as tasks (`bbs task add`, `bbs task assign`), and keeps their states current, moving each to `done` or `dropped`;
    - the orchestrator reads each team's channel with `bbs read --team TEAM`.
    Keep the closing "Keep posts short ..." line last.

## Tests (in `SkillDocumentTests`)
1. **Protocol phrases.** Add `"--team TEAM"`, `"--to team:"`, `"bbs task move NAME"`, `"bbs task add"`, and `"bbs read --team TEAM"` to the phrases the protocol test requires. Adjust them to your exact wording, but each duty needs one.
2. **Every documented subcommand exists.** A new test, beside `test_every_documented_command_exists` and in its style:
   - find every `bbs team WORD` and `bbs task WORD` in SKILL.md, with `re.findall(r"\bbbs (team|task) ([a-z]+)\b", ...)`;
   - require that the distinct pairs are exactly the six subcommands: `team` with `create`, `add`, and `remove`, and `task` with `add`, `assign`, and `move`;
   - check that `bbs.main([group, word, "--help"])` exits with 0 for each.
   Mention each subcommand in SKILL.md in that form.
3. Every existing test in the class must still pass, including the front-matter test.

## Not yours
bbs.py, and every other test class.
