# Task `schema`: the new tables and their migration

Worker `board-schema`, on branch `board/schema` from `team/board`. Read `common.md` and `design.md` beside this file first.

## Where you work
- In `.claude/skills/agent-bbs/scripts/bbs.py`, the constants (lines 60-61) and the database section (lines 631-780).
- A new test class at the end of `.claude/skills/agent-bbs/tests/test_bbs.py`.

## What is there now
Read these ranges once:
- Lines 60-61: `SCHEMA_VERSION = 1`, which is kept in SQLite's `user_version`.
- Lines 635-693: `SCHEMA`, a tuple of `CREATE TABLE IF NOT EXISTS` statements, each with a comment above it.
- Lines 696-721: `open_board()`. It connects with `timeout=BUSY_TIMEOUT_SECONDS`, turns on foreign keys and WAL, then calls `_create_schema`.
- Lines 743-758: `_create_schema(conn)`.
  - It returns at once when `user_version` equals `SCHEMA_VERSION`.
  - Otherwise, inside `write_transaction`, it reads the version again, refuses a newer one with a `UserError`, runs every statement, and sets the version.
- In the tests, lines 32-45 (the module's paths and constants), 67-77 (`environment_without_board_override` and `git()`), and 80-153 (the base classes).

The old script is this same code. It refuses any board whose `user_version` is above 1, and returns at once on a board whose version is 1. So the new tables cannot hang on the version number.

## Behavior
1. **The version.** Keep `SCHEMA_VERSION = 1`, and rewrite its comment to say three things:
   - it is the version of the base layout;
   - scripts from before teams refuse a board whose version is higher than theirs;
   - so additive changes never raise it, and `SCHEMA_ADDITIONS` applies them instead.
2. **`SCHEMA_ADDITIONS`.** Add it right after `SCHEMA`: a tuple of statements, each with a comment above it as in `SCHEMA`, in this order:

       -- Teams. `lead` is a plain agent name rather than a reference to agents, so purging
       -- or resetting agents never fails on it, and never deletes the team.
       CREATE TABLE IF NOT EXISTS teams (
           name       TEXT PRIMARY KEY,
           lead       TEXT NOT NULL,
           purpose    TEXT NOT NULL,
           created_at TEXT NOT NULL
       )
       -- Each team's members besides its lead, and when each joined. A member row goes
       -- with its team, and with its agent when the agent is purged.
       CREATE TABLE IF NOT EXISTS team_members (
           team      TEXT NOT NULL REFERENCES teams(name) ON DELETE CASCADE,
           agent     TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
           joined_at TEXT NOT NULL,
           PRIMARY KEY (team, agent)
       )
       -- Finds an agent's teams, and lets deleting an agent find its member rows quickly.
       CREATE INDEX IF NOT EXISTS team_members_by_agent ON team_members (agent)
       -- Each team's tasks. AUTOINCREMENT never reuses an id. `assignee`, `created_by`
       -- and `updated_by` are plain agent names, so a task outlives its agents; `brief`
       -- is a path, or NULL when the task has none.
       CREATE TABLE IF NOT EXISTS tasks (
           id         INTEGER PRIMARY KEY AUTOINCREMENT,
           team       TEXT NOT NULL REFERENCES teams(name) ON DELETE CASCADE,
           title      TEXT NOT NULL,
           brief      TEXT,
           state      TEXT NOT NULL DEFAULT 'open',
           assignee   TEXT,
           note       TEXT NOT NULL DEFAULT '',
           created_at TEXT NOT NULL,
           created_by TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           updated_by TEXT NOT NULL
       )
       -- Finds a team's tasks, and lets deleting a team find them quickly.
       CREATE INDEX IF NOT EXISTS tasks_by_team ON tasks (team)
       -- The paths and globs each task touches, in normalize_pattern form.
       CREATE TABLE IF NOT EXISTS task_files (
           task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
           path    TEXT NOT NULL,
           PRIMARY KEY (task_id, path)
       )

   Its `#:` comment says:
   - these came after layout 1 shipped;
   - each one is created whenever it is missing, so older scripts (which ignore them) and newer ones share one board;
   - every change here must be additive: a new table or index, never a changed column;
   - a table that refers to agents or messages must cascade or hold plain names, because older scripts delete agents and messages without knowing that the table exists.
3. **`_created_name(statement) -> str`.** A small new helper that returns the name of the table or index that one `CREATE ... IF NOT EXISTS` statement makes, from `re.search(r"IF NOT EXISTS\s+(\w+)", statement)`. Then no second list of names has to be kept in step.
4. **`_board_is_current(conn) -> bool`.** New, beside `_create_schema`: whether `user_version` equals `SCHEMA_VERSION` and every name that `SCHEMA_ADDITIONS` creates is in `sqlite_master`. It only reads.
5. **`_create_schema(conn)`.**
   - Return at once when `_board_is_current(conn)`.
   - Otherwise, inside `write_transaction`, do what it does now: read the version again; refuse a newer one with today's message; run `SCHEMA + SCHEMA_ADDITIONS`; and set the version to `SCHEMA_VERSION`.
   - Update its docstring.
6. **Nothing else.** No command uses the new tables yet.

## Tests
Add a new class, `SchemaTests(BoardTestCase)`, at the end of `tests/test_bbs.py`. Its docstring says it covers the tables added after layout 1, and the pre-teams script working beside the new one.

**Shared parts** (later tasks reuse them, so make them clean):
- **`PRE_TEAMS_COMMIT`.** A module constant, `"780f325dae8e0d2dc8b55f7147dddece9332595b"`. Its `#:` comment says it is the last commit whose bbs.py predates teams, and that its script stands in for the older copies that agents in older worktrees still run. Do not use `main`: once this team merges, main's script is the new one.
- **`setUpClass`.**
  - Call `super().setUpClass()` first.
  - Run `git show PRE_TEAMS_COMMIT:.claude/skills/agent-bbs/scripts/bbs.py` with `cwd=SKILL_DIR`, in the environment that the module's `git()` helper builds (no `GIT_*` variables). Factor that environment into a small module function that both use, to keep it DRY.
  - On a non-zero exit, `raise unittest.SkipTest("the pre-teams bbs.py is not in this repository's history")`.
  - Write the script into a temporary directory, which `cls.addClassCleanup` removes.
- **`run_old(self, *args) -> subprocess.CompletedProcess`.** Runs that script with `sys.executable`, with `cwd=self.worktree`, `capture_output=True, text=True, timeout=60`, and an environment that sets `bbs.BOARD_DIR_ENV` to `str(self.board_dir)` explicitly. It must never reach the live board.
- **`old_ok(self, *args) -> str`.** Asserts exit status 0 and empty standard error, naming the arguments in the failure message, and returns standard output.
- **`board_objects(self) -> set`** returns the names of every table and index in the board file (`SELECT name FROM sqlite_master`), and **`user_version(self) -> int`** returns its version. Both read with plain `sqlite3`, closing with `contextlib.closing`.

**Tests:**
1. A new board has every added table and index, and `user_version` 1.
2. A board made by the old script gains the tables the first time the new script opens it.
   - Old script: register two agents, claim, post to all, post to one agent with `--file`, and reply.
   - The new script then has every added table, the version is still 1, and the new script reads the old data unchanged: `json.loads(self.old_ok("read", "--json"))` equals `self.ok_json("read")`, and the same holds for `agents`.
3. The old script keeps working on a board that the new script made.
   - Run each of these with the old script, and each succeeds: `register`, `heartbeat`, `activity`, `claim`, `claims`, `post` (with `--file`, and a reply), `read`, `thread`, `inbox`, `agents`, `release --all`, `purge --older-than 1`, and `reset --yes`.
   - `watch NAME --once` exits with 2 when it prints messages: set up an unread message, and assert exactly 2.
   - After the old `reset`, the new script still opens the board, and the tables are all there.
4. Opening a current board takes no write lock.
   - After a command has made the board, hold its write lock from a second connection: `sqlite3.connect(path, isolation_level=None)`, then `BEGIN IMMEDIATE`, and `ROLLBACK` in a `finally`.
   - Patch `bbs.BUSY_TIMEOUT_SECONDS` to 0.2 with `mock.patch.object`.
   - Assert that `agents` and `read` still succeed. Explain in a comment that they would wait for the lock, and fail, if opening the board wrote anything.
5. Applying the additions is idempotent. Open the board twice with `bbs.open_board()`, closing each with `contextlib.closing`, and call `bbs._create_schema(conn)` once more. The set of objects is unchanged, and the version is still 1.
6. A board from a newer script is refused. Set `user_version` to 2 with plain `sqlite3` on a board you made; `agents` then fails with "update the agent-bbs skill".

Before your change the suite was `Ran 85 tests ... OK`. `ConcurrencyTests`, which makes a board from six processes at once, must still pass.

## Not yours
Any command, the parser, and SKILL.md.
