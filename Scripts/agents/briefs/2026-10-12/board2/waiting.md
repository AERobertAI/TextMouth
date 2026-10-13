# board2 task: joining a team before registering (task 28)

Slug `board2-waiting`, branch `board2/waiting`, board task **28**. Read `common.md` beside this file first.

## Why
`bbs team add` refuses an agent that has not registered yet, so a lead cannot add a worker before launching it. `task assign` already accepts an unregistered agent. Make `team add` accept one too: the agent **waits to join**, and joins the team when it registers, as though it had joined when it was added.

**Why a new table:** `team_members.agent` references `agents(name)` with foreign keys on, so a member row needs a registered agent. The board's layout may only grow: new tables and indexes in `SCHEMA_ADDITIONS`, never a changed column. A new table holds the waiting names.

## bbs.py (line numbers are for `team/board2` as you branch from it)
1. **The table.** Append one statement to `SCHEMA_ADDITIONS`, after the `task_files` statement and before the tuple's closing parenthesis (line 782), with a comment in the style of its neighbours. The comment should say: agents added to a team before they registered; each joins the team when it next registers, as though it had joined when it was added; `agent` and `added_by` are plain names, since the agent has no row yet; a row goes with its team.

       CREATE TABLE IF NOT EXISTS waiting_members (
           team     TEXT NOT NULL REFERENCES teams(name) ON DELETE CASCADE,
           agent    TEXT NOT NULL,
           added_at TEXT NOT NULL,
           added_by TEXT NOT NULL,
           PRIMARY KEY (team, agent)
       )

   Leave the closing parenthesis and every line after it alone: another worker edits `open_board`, just below.
2. **`add_member`** (lines 1738-1751) gains `joined_at: Optional[str] = None`, defaulting to now. Update its docstring.
3. **Joining, DRY.** Add `join_team(conn, team, agent, joined_at=None) -> bool`: `add_member`, then the "Joined team {team}" post when a row was added; it returns whether one was. `join_teams` (lines 1764-1778) uses it. Add `join_waiting_teams(conn, agent) -> List[str]` right after `join_teams`. It joins every team the agent waits for (`ORDER BY added_at, rowid`), with `joined_at` set to the row's `added_at`, deletes the agent's waiting rows, and returns the teams it joined.
4. **`cmd_register`** (lines 984-1029): `joined = join_waiting_teams(conn, name) + join_teams(conn, name, args.team)`. `join_teams` skips a team just joined, so nothing is posted twice. Update the docstring.
5. **`load_teams`** (lines 1698-1722): each team gains `"waiting"`, its waiting names `ORDER BY added_at, rowid`, always present (an empty list when none). Update the docstring.
6. **`describe_team`** (lines 1725-1735): right after the Members line, add `f"  Waiting to join: {', '.join(team['waiting'])}"`, only when the list is not empty. Every existing team's text then stays exactly as it is.
7. **`cmd_team_add`** (lines 1799-1821). The actor must still be registered and the team must exist; drop the loop that requires every agent to be registered. For each agent, in input order after normalizing and dropping repeats:
   - the lead: already ("X already leads team T.", as now);
   - registered: `add_member`, so it is added, or already ("X is already a member of team T.", as now). Either way, delete any waiting row for this team and agent. It may have registered through an older copy of the script.
   - not registered, with a waiting row: already, "X is already waiting to join team T."
   - not registered, without one: insert a waiting row (`added_at` now, `added_by` the actor). It counts as added, and as newly waiting.
   - **Channel post:** one line, as now, when anything was added: `Added {', '.join(added)} to team {team}`. Waiting names are included.
   - **Text, in this order:**
     1. `Added X, Y to team T.` when anything was added.
     2. The "already" lines, in input order.
     3. For each newly waiting name, in input order: `f"{X} has not registered yet{_did_you_mean(conn, X)}; it joins team {T} when it registers."`. Compute it inside the transaction; `_did_you_mean` is at line 921.
     4. `describe_team`.
   - **JSON:** `{"team": details, "added": [...], "already": [...], "waiting": [...]}`. `waiting` holds this command's names that wait after it, newly or already.
   - Update the docstring.
8. **`cmd_team_remove`** (lines 1824-1846): also delete a waiting row for each name. A name removed from waiting counts as removed: the same text, JSON, and channel line as for a member. Update the docstring.
9. **The parser** (`team_add`'s `agents` argument, line ~2405): `help="agents to add; one not registered yet joins when it registers"`. Touch nothing else in `build_parser`.
10. **Docstrings only:**
    - In `cmd_purge`'s docstring (lines 2098-2111), "Its members, tasks, and task files go with it." becomes "Its members, waiting members, tasks, and task files go with it."
    - In `cmd_reset`'s cascade comment (lines 2141-2143), "members, tasks, and task files with the teams" becomes "members, waiting members, tasks, and task files with the teams".
    - The cascade does the work in both.

## Tests (test_bbs.py)
`TeamTests` (lines 922-1241) registers chief, alpha, beta, and gamma in `setUp`, and has `create()` and `channel()` helpers. The other helpers are `register_into` (line ~1146), and `clock()` and `NOON` from `BoardTestCase`. Use `delta` as the agent that has not registered, and `betta` as a typo of `beta`.
- **Update:**
  - `test_creating_a_team_makes_the_actor_its_lead_and_reports_every_field` gains `"waiting": []`.
  - Replace `test_an_unknown_agent_adds_nobody` (lines 1057-1063) with `test_a_mistyped_name_waits_and_gets_a_hint`. `team add chief board alpha betta` adds both. Its text has `betta has not registered yet (did you mean 'beta'?); it joins team board when it registers.`
- **New, at the end of `TeamTests`:**
  - `test_an_agent_added_before_it_registers_waits_then_joins_when_it_registers`. `team add chief board delta` prints `Added delta to team board.`, then `delta has not registered yet; it joins team board when it registers.`
    - `teams board` text has `  Waiting to join: delta`. Its JSON has members `[]` and waiting `["delta"]`. The channel's last post is "Added delta to team board", from chief.
    - Registering delta without `--team` prints `Joined team board.`, and its JSON `joined` is `["board"]`. The team now has members `["delta"]` and waiting `[]`, and the channel gets "Joined team board" from delta.
  - `test_a_waiting_agent_hears_the_channel_from_when_it_was_added`. Use `clock()` for four moments: chief posts "before" to `team:board`, chief adds delta, chief posts "after", and delta registers. delta's `inbox --json` holds "after" and not "before".
  - `test_registering_with_team_for_a_team_it_waits_for_joins_once`: delta waits, then `register_into("delta", "board")`. That gives one `Joined team board.` line and one "Joined team board" post.
  - `test_adding_a_waiting_agent_again_says_so_and_posts_nothing`. The second add prints `delta is already waiting to join team board.` and posts no new channel line. Its JSON has added `[]`, already `["delta"]`, and waiting `["delta"]`.
  - `test_removing_a_waiting_agent_stops_it_joining`. `team remove` prints `Removed delta from team board.`, and the team's waiting list is empty. Registering delta afterwards gives JSON `joined == []`.
  - `test_a_waiting_agent_goes_with_its_team`: delta waits, then `reset --yes`. Register chief again and create board again. Registering delta then gives `joined == []`.
- **`SchemaTests`:**
  - Add `"waiting_members"` to `ADDED` (line 1741).
  - Add, as the last method of `SchemaTests` (right before `class TaskTests`), `test_an_agent_the_old_script_registers_joins_when_added_again`. Use the new script to register chief, create board, and add delta, who waits. The pre-teams script (`old_ok`) registers delta and does not join it, so `teams` still shows delta waiting. `team add chief board delta` then prints `Added delta to team board.`, with members `["delta"]` and waiting `[]`.
- Fix any other existing test that compares a whole team dict.

## SKILL.md
- **Line 49:** "`bbs team add NAME TEAM AGENT ...` adds agents as members. An agent that has not registered yet waits to join, and joins when it registers, hearing the channel from when it was added; `teams` lists it under "Waiting to join". An agent can also join with `register --team`."
- **Line 56:** "A member hears the channel from when it joined" becomes "A member hears the channel from when it joined, or from when it was added if that was before it registered".
- **After line 58,** a new paragraph: "Older copies of the script know nothing of waiting members: one that registers a waiting agent leaves it waiting. Run `team add` again once the agent has registered."
- **Line 120 (purge):** "together with its members and tasks" becomes "together with its members, waiting members, and tasks".
- **Protocol item 8 (line 142):** "A lead creates the team with `bbs team create NAME TEAM --purpose "ONE LINE"`, may add each worker before launching it with `bbs team add NAME TEAM AGENT`, hands out work with ...". Leave the rest of the item as it is.

## Commits
One commit: "Let team add take an agent that has not registered yet".

## Not yours
- Everything from `SCHEMA_ADDITIONS`' closing parenthesis down to the claims code, which holds the discovery code and `open_board`.
- The task functions, and `build_parser` beyond the one help string.
- Test classes other than `TeamTests` and the two `SchemaTests` spots.
- SKILL.md outside the lines above.
