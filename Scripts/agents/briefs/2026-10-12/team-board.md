# Team board: teams, subforums, and task lists on the message board

Team `board`; lead `board-lead`; team branch `team/board`; workers' branches `board/<task>`. Read `teams-common.md` beside this file first.

## What the user asked
On October 12: "maybe build out the bbs so if its not already allows for agent teams / subforums basically for them to communicate".

## What the board has today
`.claude/skills/agent-bbs/` holds the board:
- `scripts/bbs.py`, a 1,779-line standard-library script;
- `tests/test_bbs.py`, 1,109 lines of unittest;
- `SKILL.md`, the reference, with the protocol between its `protocol:begin` and `protocol:end` markers;
- `scripts/build-slot-with-bbs.sh`, the build wrapper.

It already has:
- agents and their claims on files;
- messages to one agent, to `all`, or tied to files;
- threads and an inbox, `watch`, and housekeeping.

It has no teams, no channels, and no task lists. The board is one SQLite file that every worktree shares (`$TEXTMOUTH_BBS_DIR/board.sqlite` when set, else `.claude/agent-bbs/board.sqlite` in the main checkout).

## What to build
1. **Teams.** A team has a name, a lead, members, and a one-line purpose.
   - Create a team with its lead and purpose; add and remove members; list teams (with lead, members, and open tasks); show one team.
   - Registering may join a team at once.
   - An agent may belong to several teams.
   - Decide how a team is addressed and say why. The recommendation is `team:<name>` wherever a message names its reader, so team names never clash with agent names or with `all`.
2. **Channels (the user's "subforums").**
   - A post to a team reaches the inbox of its lead and every member.
   - `read` can show one team's channel.
   - `inbox` and `watch` can be limited to one team.
   - Replies stay in the channel of the message they answer.
   - Messages tied to files keep reaching the agents whose claims cover them, as today.
3. **Task lists.** Each team keeps a list of tasks.
   - A lead adds a task with a one-line title, and optionally a brief's path and the files it touches.
   - A task is assigned to an agent, and moves through `open`, `assigned`, `working`, `review`, `done`, and `dropped`, with an optional note.
   - Tasks can be listed by team, by state, or by agent.
   - Every change posts one short line to the team's channel, so the channel is the team's history.
4. **Compatibility with the live board.** Agents are using the live board as you work, from older copies of `bbs.py` in their own worktrees.
   - Every change to the schema is additive (new tables, new nullable columns, new indexes). The new script applies it idempotently.
   - The old script must keep working on a board the new one has migrated. Prove it with a test that runs main's script against a migrated temporary board (`git show main:.claude/skills/agent-bbs/scripts/bbs.py`), and one that runs the new script on a board the old one made.
   - Every test uses a temporary board (`TEXTMOUTH_BBS_DIR`), never the live one.
   - No run of the new script during your work may touch the live board except plain coordination commands: `register`, `post`, `inbox`, `claims`, and `read`.
5. **Tests.** Extend `tests/test_bbs.py` to cover each new command, the channel routing, the task states, and both compatibility cases. Run them with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`.
6. **Documents.** Document the new commands in `SKILL.md`, and add to the protocol a short team etiquette:
   - a worker posts to its team's channel;
   - a lead hands out work as tasks and keeps their states current;
   - the orchestrator reads the channels.

   `SKILL.md` is the one `*.md` file this team may edit.
7. **Style.** One standard-library file, with the script's docstring-and-comment style, readable text output, and `--json` on every new command. The topic and body limits stay as they are.

## How to split it
No task here builds the app, so this team never takes a build slot. A sensible split, which you may change:
- **First,** the schema, its migration, and teams.
- **Then, in parallel,** channels and task lists.
- **Last,** the documents and the compatibility tests.

Each task's brief should name the functions and line ranges in `bbs.py` it touches, and how its commands fit the existing parser.

## Not this team's
- The app's code.
- The build wrapper's slot logic.
- The orchestrator's scripts in `Scripts/agents/`.

## The suite
Your team branch changes no Swift. Instead of the app's full suite, run the board's tests on the rebased team branch, and report their result line ("Ran N tests … OK") in the suite's place.
