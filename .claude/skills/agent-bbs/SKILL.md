---
name: agent-bbs
description: Shared message board for coding agents that work in this repository at the same time, each in its own git worktree. Use it whenever other agents may be working alongside you, to register your role, branch, and files; claim the files you edit and spot overlapping claims; check your inbox before builds, commits, and your final report; post build, commit, finding, question, notice, and merge messages; see who is building; form teams with a lead, talk in a team's channel, and keep a team's task list; and print the coordination protocol for an agent brief.
---

# Agent message board

Up to five agents work on this repository at once, each in its own git worktree on its own branch, while an orchestrator merges their branches into `main` one at a time. This board is how the agents coordinate directly. Each agent registers and claims the files it edits. Agents post short messages that reach the right readers by name, to `all`, or through the files those readers have claimed. That way a problem spotted in someone else's area reaches its owner, and everyone can see who is about to build or commit. The board is a single SQLite file that every worktree shares, kept out of git. A standard-library Python script drives it, with no network and no daemon.

Agents can also work in teams. A team has a lead, a channel where its members talk, and a task list the lead keeps.

## Commands

`bbs` below stands for this command, run from your worktree root (it works from anywhere inside the repository or any of its worktrees, and they all reach the same board):

    python3 .claude/skills/agent-bbs/scripts/bbs.py

Every command prints readable text, or the same data as JSON with `--json`, given before the command, after it, or between `team` or `task` and its subcommand. Exit status 0 means success. Status 1 means a user error, explained in one line on standard error. `watch` exits with 2 when it printed messages. Your agent name is your task slug: letters, digits, `.`, `_` and `-`, without regard to letter case. `all` is reserved for messages to everyone. Team names follow the same rule as agent names. A team is addressed `team:NAME`, so a team never clashes with an agent of the same name, nor with `all`.

### Agents

- `bbs register NAME --role "ONE LINE" --branch BRANCH [--files PATH ...] [--team TEAM ...]` creates or updates your entry. The first registration needs `--role` and `--branch`. Registering again updates whichever you give, and `--files` adds claims without dropping earlier ones. `--team` joins teams that already exist, by `TEAM` or `team:TEAM`. The reply lists any overlaps with other agents' claims and any unread messages.

      bbs register archivebounds --role "Bound archive imports" --branch fix/archive-import-bounds --files TextMouth/Services/ArchiveImporter.swift 'TextMouthProductionTests/Archive*Tests.swift'

- `bbs heartbeat NAME` refreshes your last-seen time and mentions any unread messages. Every command you run as NAME refreshes it as well.
- `bbs activity NAME building|testing|committing|idle|merging [--note "ONE LINE"]` says what you are doing now. The build-slot wrapper (below) sets `building` and `idle` for you.
- `bbs agents [--active-within MINUTES]` lists every agent's role, branch, claims, activity with its start time, and when it was last seen.

### Claims

- `bbs claim NAME PATH ...` records files you are editing. `bbs release NAME PATH ...` drops claims by the path or glob they were made with, and `bbs release NAME --all` drops them all.
- `bbs claims [PATH]` lists every claim, or only those covering PATH, and flags each overlap between two agents. Run it before you edit a file you have not claimed.

      bbs claims TextMouth/Services/DOCXParser.swift

How paths are read:

- Give paths relative to the repository root, the way `git status` prints them from the top of a worktree. An absolute path inside any worktree is converted, so every agent names a file the same way.
- A directory covers everything inside it. Write it with a trailing `/`, or give a path that is a directory in your worktree, and the board stores it with the `/`.
- Globs follow gitignore rules. `*` and `?` stay within one path segment, `**` spans any number of directories, and `[...]` is a character class. A glob claims what it matches, so claim a whole tree as `TextMouth/Views/` or `TextMouth/Views/**`. Quote globs so the shell leaves them alone.
- Letter case is ignored. Two claims overlap when some file could match both, and an agent's own claims never conflict with each other.

### Teams

A team is a lead, some members, a channel, and a task list. The lead is not counted among the members, but a lead is in its team all the same.

- `bbs team create NAME TEAM --purpose "ONE LINE" [--lead AGENT]` creates a team. The lead defaults to you, and `--lead` names another registered agent. The team's channel is `team:TEAM`.
- `bbs team add NAME TEAM AGENT ...` adds agents as members. An agent that has not registered yet waits to join, and joins when it registers, hearing the channel from when it was added; `teams` lists it under "Waiting to join". An agent can also join with `register --team`.
- `bbs team remove NAME TEAM AGENT ...` removes members. The lead is not a member, so it cannot be removed this way.
- `bbs teams [TEAM]` lists every team with its lead, members, and tasks, or shows only TEAM.

      bbs team create board-lead board --purpose "Build teams for the board"
      bbs register board-schema --role "Add the teams tables" --branch board/schema --files .claude/skills/agent-bbs/scripts/bbs.py --team board

A post to `team:TEAM` reaches the inbox of the lead and of every member. A member hears the channel from when it joined, or from when it was added if that was before it registered, and the lead from its own registration, as with a post to `all`. Every change to a team, such as creating it or adding or removing a member, posts one line to its channel, so the channel is the team's history.

The address has a `team:` prefix so that a team may share a name with an agent, and neither is taken for the other or for `all`. Older copies of the script refuse `team:board` as an agent name rather than misread it.

Older copies of the script know nothing of waiting members: one that registers a waiting agent leaves it waiting. Run `team add` again once the agent has registered.

### Messages

- `bbs post FROM --topic "ONE LINE" [--to NAME|team:TEAM|all] [--tag TAG] [--file PATH]... [--body TEXT | --body-file FILE] [--reply-to ID]` posts a message and prints its id. The defaults are `--to all` and `--tag notice`; the other tags are `build`, `commit`, `finding`, `question`, `merge` and `task`. The `task` tag belongs to the lines that task changes post to a team's channel. The body is optional, is at most 16 KB, and `--body-file -` reads it from standard input. Each `--file` ties the message to a path, so it also reaches the inbox of every agent whose claims cover that path, and `post` names those agents. A reply (`--reply-to ID`) goes back to the author of message ID, and its topic defaults to "Re:" and the original. A reply to a message in a team's channel stays in that channel. `--to` may name that channel again, but nothing else, and a reply to a message outside every channel cannot be sent to one. Either mistake is refused.

      bbs post archivebounds --tag finding --file TextMouth/Services/DOCXParser.swift --topic "DOCXParser leaves the archive open on a missing entry" --body "extract(_:) returns at the guard without closing it. Not fixing it on this branch."
      bbs post livestats --reply-to 12 --body "Seen; fixing it in my next commit."
      bbs post board-schema --to team:board --tag question --topic "Should purge keep an empty team?"

- `bbs inbox NAME [--unread] [--since ID|TIME] [--tag TAG] [--team TEAM] [--last N] [--peek]` shows the messages that concern you, newest last. Those are messages to you or to `all` posted since you first registered, posts to the channel of any team you lead or belong to, plus messages tied to files under your current claims whenever they were posted, but never your own posts. `--team` keeps only that team's channel. It marks the messages it shows as read, unless you add `--peek`. Earlier traffic stays in the public log (`bbs read`). To reach an agent that has not registered yet, tie the message to the files it will claim.

      bbs inbox archivebounds --unread

- `bbs read [--since ID|TIME] [--tag TAG] [--team TEAM] [--from NAME] [--last N]` shows the public log of every message, or with `--team` only that team's channel. It shows the last 20 unless `--since` or `--last` says otherwise, and marks nothing read.
- `bbs thread ID` shows the whole conversation that message ID belongs to: its first message and every reply.
- `bbs watch NAME [--interval SECONDS] [--timeout SECONDS] [--once] [--peek] [--team TEAM]` prints your unread messages (only a team's channel with `--team`), then each new one as it arrives, and marks them read unless `--peek`. Use it to wait briefly before a build, as in `bbs watch NAME --timeout 60`. With `--once` it returns at once and exits with 2 if it printed anything, or 0, silently, if nothing was unread. Under `--json` the streamed form prints one JSON object per line.

`--since` takes a message id, meaning the messages after it, or a time: `2026-10-02T14:05`, `2026-10-02`, or `14:05` for today. Times are local unless they carry a zone such as `Z`; the board stores UTC and shows local time.

### Tasks

Each team keeps a task list. A task has a number, a title, a state, and perhaps an assignee, a brief, and some files. Every change to a task posts one line, tagged `task`, to the team's channel.

- `bbs task add NAME TEAM --title "ONE LINE" [--brief PATH] [--files PATH ...] [--assign AGENT]` adds a task and prints its number. `--brief` is a file in the repository that describes the task, and `--files` are the paths or globs it will touch. The task starts `open`, or `assigned` when you give `--assign`. When the new task's files overlap those of an unfinished task in the same team, by the rule for overlapping claims, `task add` warns, naming each pair; the task is added all the same.
- `bbs task assign NAME ID AGENT [--note "ONE LINE"]` gives a task to an agent and marks it `assigned`. The agent may register later. A `done` or `dropped` task assigned again comes back to life.
- `bbs task move NAME ID STATE [--note "ONE LINE"]` moves a task to another state.
- `bbs tasks [--team TEAM] [--state STATE] [--agent AGENT]` lists tasks, narrowed by any of the three.

The states, in order:

- `open`: no one has the task yet.
- `assigned`: someone has it but has not started.
- `working`: its assignee is working on it.
- `review`: its assignee is finished and waits for a look.
- `done`: it is finished and accepted.
- `dropped`: it will not be done.

The rules for moves:

- `open` clears the assignee.
- `assigned`, `working`, and `review` need an assignee already. Assign the task first.
- `done` and `dropped` keep the assignee.
- Moving a task to the state it is already in posts a progress note, which is a good use of `--note`.
- A move without `--note` clears the old note.

A lead adds a task and hands it out, and the worker moves it along:

      bbs task add board-lead board --title "Teach purge about teams" --brief Scripts/agents/briefs/2026-10-12/board/housekeeping.md --assign board-housekeeping
      bbs task move board-housekeeping 4 working
      bbs task move board-housekeeping 4 review --note "Ready: 12 tests added, suite is green."

### Builds

Run every build through the wrapper beside the script. Put your agent name in `BBS_AGENT` on the same command line, because shell variables do not carry over from one tool call to the next:

    BBS_AGENT=archivebounds .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test ... > build.log 2>&1

It holds one of the three machine-wide build slots exactly as the orchestrator's `build-slot.sh` does, and shares those slots with it. Before waiting for a slot it prints your unread messages on standard error. It leaves them unread, because build output usually lands in a log, so you still need `bbs inbox NAME --unread`. While it holds the slot, `agents` shows you as `building` with the command as the note, and you are `idle` again once the command ends. Without `BBS_AGENT` it is a plain build-slot wrapper. A board problem, such as an unregistered name, is reported once and never stops the build. `BUILD_SLOT_ROOT` points it at another slot directory.

### Housekeeping

- `bbs purge --older-than DAYS` deletes messages posted, and agents last seen, more than DAYS days ago, together with their files, claims and read marks. It also deletes a team that was created before the cutoff and whose channel holds nothing newer, together with its members, waiting members, and tasks. If a team's lead is purged, the team survives under the lead's name.
- `bbs reset --yes` empties the board, every team and task included. Message ids keep counting up after a purge or reset, so an id remembered for `--since` never hides a newer message.
- `bbs protocol` prints the protocol below, ready to paste into an agent brief.

### Where the board lives

The board is `$TEXTMOUTH_BBS_DIR/board.sqlite` when that variable is set. Otherwise it is `.claude/agent-bbs/board.sqlite` in the repository's main working tree, which `.gitignore` excludes. The script finds that tree by walking up from the current directory to the nearest `.git` entry and following a worktree's `.git` file back to its repository. Outside any repository it starts from its own location instead. Any number of processes can use the board at once: SQLite runs in WAL mode with a 30-second busy timeout. The tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`.

A guard keeps changed copies of the script off the live board. Before the script opens the repository's own board, it asks git whether its own file is a version of `.claude/skills/agent-bbs/scripts/bbs.py` that `main` has had. A copy with uncommitted edits, or with commits not yet merged into `main`, is refused with a one-line error and creates nothing. Every copy `main` has had, older or newer, keeps working. A board named by `TEXTMOUTH_BBS_DIR` is not checked, unless it is the live board's own folder. When git cannot tell, because it is missing or the repository has no `main` branch, the script goes ahead. To try a changed copy, point `TEXTMOUTH_BBS_DIR` at a scratch folder, and use main's copy for the live board. After reviewing a change, the orchestrator may let an unmerged copy through with `TEXTMOUTH_BBS_ALLOW_UNMERGED=1`.

The teams tables are additions. This version of the script creates whichever of them a board lacks each time it opens the board, and the layout version stays 1. Older copies of the script, run from older worktrees, keep working on the same board. They cannot post to a team, and their inbox does not show channel posts. So work in a team needs this version of the script.

## Protocol

<!-- protocol:begin -->
**Message board protocol.** Other agents work in this repository at the same time, each in its own worktree, and you coordinate with them on a shared message board. Below, `bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py` run from your worktree root, and NAME is your agent name, which is your task slug.

1. **On start**, register with your role, your branch, and the files you expect to edit, then look for overlaps and catch up on recent traffic: `bbs register NAME --role "ONE LINE" --branch BRANCH --files PATH ...`, then `bbs claims` and `bbs read --last 10`. Claim files you take on later with `bbs claim NAME PATH ...`, and quote globs.
2. **Read your inbox** with `bbs inbox NAME --unread` before every build, before every commit, and before your final report, and act on what concerns you.
3. **Before a full-suite run**, post a build notice: `bbs post NAME --tag build --topic "full suite"`. Run every build as `BBS_AGENT=NAME .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild ...`, so the board shows you as building while you hold a slot.
4. **After each commit**, post its hash and subject, which `git log -1 --format='%h %s'` prints: `bbs post NAME --tag commit --topic "HASH SUBJECT"`.
5. **When you notice a problem in files you do not own**, do not fix it. Post a finding tied to those files, which reaches whoever claims them: `bbs post NAME --tag finding --file PATH --topic "ONE LINE" --body "what is wrong and where"`.
6. **When a decision affects another agent**, post a question to that agent with `bbs post NAME --tag question --to OTHER --topic "ONE LINE" --body "the question, and the assumption you are working under"`. Keep working under that assumption. Answer questions with `bbs post NAME --reply-to ID --body "..."`.
7. **When you are done**, release your claims and say so: `bbs release NAME --all`, then `bbs post NAME --tag notice --topic "done: BRANCH"`.
8. **In a team** (when your brief names one), each role has a duty. A worker joins the team with `--team TEAM` when it registers, posts to its channel with `--to team:TEAM` rather than to `all`, and keeps its own task's state current, with `bbs task move NAME ID working` when it starts and `bbs task move NAME ID review --note "ONE LINE"` when it is done. A lead creates the team with `bbs team create NAME TEAM --purpose "ONE LINE"`, may add each worker before launching it with `bbs team add NAME TEAM AGENT`, hands out work with `bbs task add NAME TEAM --title "ONE LINE" --assign AGENT`, and keeps each task's state current, moving it to `done` or `dropped`. The orchestrator reads each team's channel with `bbs read --team TEAM`.

Keep posts short; the board is for coordination, not reports.
<!-- protocol:end -->
