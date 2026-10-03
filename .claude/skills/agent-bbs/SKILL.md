---
name: agent-bbs
description: Shared message board for coding agents that work in this repository at the same time, each in its own git worktree. Use it whenever other agents may be working alongside you, to register your role, branch, and files; claim the files you edit and spot overlapping claims; check your inbox before builds, commits, and your final report; post build, commit, finding, question, notice, and merge messages; see who is building; and print the coordination protocol for an agent brief.
---

# Agent message board

Up to five agents work on this repository at once, each in its own git worktree on its own branch, while an orchestrator merges their branches into `main` one at a time. This board is how the agents coordinate directly. Each agent registers and claims the files it edits. Agents post short messages that reach the right readers by name, to `all`, or through the files those readers have claimed. That way a problem spotted in someone else's area reaches its owner, and everyone can see who is about to build or commit. The board is a single SQLite file that every worktree shares, kept out of git. A standard-library Python script drives it, with no network and no daemon.

## Commands

`bbs` below stands for this command, run from your worktree root (it works from anywhere inside the repository or any of its worktrees, and they all reach the same board):

    python3 .claude/skills/agent-bbs/scripts/bbs.py

Every command prints readable text, or the same data as JSON with `--json`. Exit status 0 means success. Status 1 means a user error, explained in one line on standard error. `watch` exits with 2 when it printed messages. Your agent name is your task slug: letters, digits, `.`, `_` and `-`, without regard to letter case. `all` is reserved for messages to everyone.

### Agents

- `bbs register NAME --role "ONE LINE" --branch BRANCH [--files PATH ...]` creates or updates your entry. The first registration needs `--role` and `--branch`. Registering again updates whichever you give, and `--files` adds claims without dropping earlier ones. The reply lists any overlaps with other agents' claims and any unread messages.

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

### Messages

- `bbs post FROM --topic "ONE LINE" [--to NAME|all] [--tag TAG] [--file PATH]... [--body TEXT | --body-file FILE] [--reply-to ID]` posts a message and prints its id. The defaults are `--to all` and `--tag notice`; the other tags are `build`, `commit`, `finding`, `question` and `merge`. The body is optional, is at most 16 KB, and `--body-file -` reads it from standard input. Each `--file` ties the message to a path, so it also reaches the inbox of every agent whose claims cover that path, and `post` names those agents. A reply (`--reply-to ID`) goes back to the author of message ID, and its topic defaults to "Re:" and the original.

      bbs post archivebounds --tag finding --file TextMouth/Services/DOCXParser.swift --topic "DOCXParser leaves the archive open on a missing entry" --body "extract(_:) returns at the guard without closing it. Not fixing it on this branch."
      bbs post livestats --reply-to 12 --body "Seen; fixing it in my next commit."

- `bbs inbox NAME [--unread] [--since ID|TIME] [--tag TAG] [--last N] [--peek]` shows the messages that concern you, newest last. Those are messages to you or to `all` posted since you first registered, plus messages tied to files under your current claims whenever they were posted, but never your own posts. It marks the messages it shows as read, unless you add `--peek`. Earlier traffic stays in the public log (`bbs read`). To reach an agent that has not registered yet, tie the message to the files it will claim.

      bbs inbox archivebounds --unread

- `bbs read [--since ID|TIME] [--tag TAG] [--from NAME] [--last N]` shows the public log of every message. It shows the last 20 unless `--since` or `--last` says otherwise, and marks nothing read.
- `bbs thread ID` shows the whole conversation that message ID belongs to: its first message and every reply.
- `bbs watch NAME [--interval SECONDS] [--timeout SECONDS] [--once] [--peek]` prints your unread messages, then each new one as it arrives, and marks them read unless `--peek`. Use it to wait briefly before a build, as in `bbs watch NAME --timeout 60`. With `--once` it returns at once and exits with 2 if it printed anything, or 0, silently, if nothing was unread. Under `--json` the streamed form prints one JSON object per line.

`--since` takes a message id, meaning the messages after it, or a time: `2026-10-02T14:05`, `2026-10-02`, or `14:05` for today. Times are local unless they carry a zone such as `Z`; the board stores UTC and shows local time.

### Builds

Run every build through the wrapper beside the script. Put your agent name in `BBS_AGENT` on the same command line, because shell variables do not carry over from one tool call to the next:

    BBS_AGENT=archivebounds .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test ... > build.log 2>&1

It holds one of the three machine-wide build slots exactly as the orchestrator's `build-slot.sh` does, and shares those slots with it. Before waiting for a slot it prints your unread messages on standard error. It leaves them unread, because build output usually lands in a log, so you still need `bbs inbox NAME --unread`. While it holds the slot, `agents` shows you as `building` with the command as the note, and you are `idle` again once the command ends. Without `BBS_AGENT` it is a plain build-slot wrapper. A board problem, such as an unregistered name, is reported once and never stops the build. `BUILD_SLOT_ROOT` points it at another slot directory.

### Housekeeping

- `bbs purge --older-than DAYS` deletes messages posted, and agents last seen, more than DAYS days ago, together with their files, claims and read marks.
- `bbs reset --yes` empties the board. Message ids keep counting up after a purge or reset, so an id remembered for `--since` never hides a newer message.
- `bbs protocol` prints the protocol below, ready to paste into an agent brief.

### Where the board lives

The board is `$TEXTMOUTH_BBS_DIR/board.sqlite` when that variable is set. Otherwise it is `.claude/agent-bbs/board.sqlite` in the repository's main working tree, which `.gitignore` excludes. The script finds that tree by walking up from the current directory to the nearest `.git` entry and following a worktree's `.git` file back to its repository. Outside any repository it starts from its own location instead. Any number of processes can use the board at once: SQLite runs in WAL mode with a 30-second busy timeout. The tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`.

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

Keep posts short; the board is for coordination, not reports.
<!-- protocol:end -->
