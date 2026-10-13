# Task `channels`: team channels in post, read, inbox, and watch

Worker `board-channels`, on branch `board/channels` from `team/board`. Read `common.md` and `design.md` beside this file first. Two other workers change bbs.py at the same time, `board-tasks` and `board-housekeeping`, in other functions. Stay inside the functions named here, so that the three branches fit together.

## What earlier tasks added
These are already on `team/board`:
- the `teams` and `team_members` tables;
- `TEAM_PREFIX = "team:"`;
- `team_address(team)`;
- `require_team(conn, raw)`, which takes `board` or `team:board` and returns `board`, or raises with "did you mean";
- `post_to_team`, `insert_message`, and `add_member`;
- the commands `team create`, `team add`, and `teams`.

Creating a team posts "Created team ..." to its channel, and `team add` posts "Added ...". Get the current lines with:

    grep -nE "^def (team_address|require_team|resolve_recipient|cmd_post|message_filters|cmd_read|collect_inbox|cmd_inbox|take_unread|cmd_watch)|post = command|read = command|inbox = command|watch = command" .claude/skills/agent-bbs/scripts/bbs.py

Read those functions and parser blocks once.

## Behavior
1. **`team_from_address(address) -> Optional[str]`.** Add it in the Teams section, right after `team_address`. It returns the team's name when the address starts with `TEAM_PREFIX`, and otherwise None.
2. **`resolve_recipient(conn, raw, sender, parent)`.** Rewrite its docstring to cover these rules.
   - **No `--to`, and no parent:** `all`, as now.
   - **No `--to`, replying to a team's message:** the parent's address, even when the sender wrote the parent.
   - **No `--to`, replying to any other message:** as now.
   - **`--to` naming a team** (the stripped, lower-cased text starts with `team:`): `team_address(require_team(conn, raw))`. Posting to your own team is fine, since it reaches the others.
   - **`--to` naming `all` or an agent:** as now.
   - **A reply to a team's message**, with `--to` naming anything but that same address, raises `UserError`:

         #{id} is in team {team}'s channel, and a reply stays there; leave out --to, or post without --reply-to

   - **A reply to a message outside every channel**, with `--to` naming a team, raises:

         #{id} is not in a team's channel, and a reply stays where the message it answers was posted; post to {address} without --reply-to

3. **The `post` parser's `--to` help** becomes: "an agent name, team:TEAM for a team's channel, or 'all' (default: all; a reply goes back to the author of the message it answers, or stays in its team's channel)".
4. **`message_filters(conn, args)`.** It gains `conn`, and a third filter. When `args.team` is set, it adds `m.recipient = ?` with `team_address(require_team(conn, args.team))`. Update its two callers, `cmd_read` and `cmd_inbox`, and its docstring.
5. **`team_channels(conn, name, registered) -> Dict[str, str]`.** Add it in the Inbox section, right before `collect_inbox`. It maps the address of each team the agent is in onto the moment from which that channel's posts concern it:
   - for a team it leads (`teams.lead`), `registered`, as for posts to `all`;
   - for a team it is a member of, its `joined_at`.
6. **`collect_inbox`.** Its filter gains a third case: the recipient is in `team_channels(...)`, and the post is no older than that channel's moment. The other cases stay as they are: own posts never count, and posts tied to files reach claimants whatever their recipient. Extend the docstring to say so.
7. **`take_unread(conn, name, *, after=0, peek=False, team=None)`.** With `team` set, it adds `m.recipient = ?` with that team's address.
8. **`cmd_watch`.** In its first transaction, beside `require_agent`, set `team = None if args.team is None else require_team(conn, args.team)`. Pass `team` to every `take_unread` call: under `--once`, and in the loop.
9. **`--team TEAM`** goes on `read`, `inbox`, and `watch`, with the help "only messages in this team's channel (TEAM or team:TEAM)".

## Tests
Add a new class, `ChannelTests(BoardTestCase)`, placed right before `class InboxTests`. Its docstring reads: posts to a team's channel, replies there, and who receives them.

In `setUp`, under `with self.clock(NOON - dt.timedelta(hours=1)):`, register `lead`, `alpha`, `beta`, and `outsider`; create team `board` led by `lead`; and add `alpha` and `beta` with `team add lead board alpha beta`. Those two lines take message ids 1 and 2. The fixed clock keeps every later `self.clock(NOON ...)` after `setUp`; without it, `setUp` would run at today's real time, after NOON.
1. **Posting to a team.**
   - A post to `team:board` is stored with `to` `team:board`.
   - Its text says `Posted #3 (notice) to team:board.`.
   - It reaches the inboxes of `lead`, `alpha`, and `beta` (the sender's own excepted), and not `outsider`'s.
2. **Addresses.** `--to Team:Board` is stored as `team:board`. `--to team:nope` fails with "there is no team 'nope'", and `--to team:bord` with "did you mean 'board'".
3. **Replies stay in the channel.**
   - A reply without `--to` to a team's post goes to `team:board`, including when the sender wrote the post being answered.
   - `--to team:board` on that reply is accepted.
   - `--to alpha` and `--to all` on it fail with "a reply stays there".
   - A reply to a post to `all`, with `--to team:board`, fails with "not in a team's channel".
4. **`read --team`.**
   - `read --team board` shows exactly the channel, including the two team lines from `setUp`.
   - `read --team team:board` shows the same.
   - `read --team nope` fails.
   - `read --team board --tag notice` combines the filters.
5. **A member who joins later** does not get the channel's earlier posts as unread. Use `self.clock`: post at noon, add `gamma` at 12:05, post at 12:10. `gamma`'s inbox holds the "Added gamma ..." line and the 12:10 post, not the noon post.
6. **The lead** gets members' posts to the channel. Its own posts, including "Created team board ...", never reach its own inbox.
7. **Files still count.** A team post with `--file` reaches `outsider` when `outsider` claims that file.
8. **`inbox --team` and `watch --team`.**
   - `inbox alpha --team board --unread` shows only the channel's posts, and leaves alpha's other unread posts unread.
   - `watch alpha --once --team board` does the same, with exit status 2 when it printed messages and 0 when it did not.
   - An unknown team fails both.
9. **Reminders count channel posts.** `heartbeat alpha` mentions its unread channel posts.

Every existing test must pass unchanged.

## Not yours
- The Teams section, apart from `team_from_address`.
- `cmd_register`, `cmd_purge`, `cmd_reset`, and anything about tasks.
- TAGS. The `tasks` worker adds a `task` tag.
