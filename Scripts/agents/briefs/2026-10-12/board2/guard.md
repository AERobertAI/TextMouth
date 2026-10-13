# board2 task: the live-board guard (task 27)

Slug `board2-guard`, branch `board2/guard`, board task **27**. Read `common.md` beside this file first.

## Why
The board's rule "never run a changed copy of `bbs.py` against the live board" is only written down. One worker broke it, and its unfinished copy created new tables on the live board early. Make the rule mechanical.

**The constraint:** at any time, agents in other worktrees run older or newer committed copies of the script against the same live board, and each must keep working. A guard may not stop a copy merely for differing from main's current copy.

## The design (decided: implement it as written)
**The live board accepts only copies of the script that `main` has had.** Before `open_board()` opens the repository's own board, the script asks git whether its own file's content is the content of `.claude/skills/agent-bbs/scripts/bbs.py` at some commit reachable from `refs/heads/main`.
- A copy with uncommitted edits is refused, and so is one with commits not on main yet, such as a worker's branch or a team branch.
- Every copy main has had, older or newer, passes.
- A scratch board named by `TEXTMOUTH_BBS_DIR` is never checked, unless that variable names the live board's own folder.
- When git cannot tell, the script goes ahead. That covers git missing, a timeout, no `main` branch, and an unreadable file. The board must keep working for everyone.

## bbs.py (line numbers are for `team/board2` as you branch from it)
1. **Imports** (lines 25-44): add `import subprocess`, in alphabetical order.
2. **Constants,** right after `BOARD_FILENAME` (line 59), each with a `#:`-style comment like its neighbours:
   - `ALLOW_UNMERGED_ENV = "TEXTMOUTH_BBS_ALLOW_UNMERGED"`. Set to anything but empty or `0`, it lets a copy main has never had open the live board. It is for the orchestrator, after review.
   - `REFERENCE_BRANCH = "refs/heads/main"`: the branch whose history decides which copies may open the live board.
   - `SCRIPT_PATH_IN_REPOSITORY = ".claude/skills/agent-bbs/scripts/bbs.py"`: where the script lives in the repository, as git names it.
   - `SCRIPT_FILE = Path(__file__).resolve()`: this script's own file.
   - `GIT_TIMEOUT_SECONDS = 10.0`.
3. **A refactor of discovery, with no change in behavior** (lines 625-656). This is its own commit.
   - `discovery_starts() -> List[Path]`: the current directory, skipped if it is gone, then `SCRIPT_FILE.parent`. Move the body out of `board_directory()`.
   - `repository_root(starts) -> Path`: today's `repository_board_directory` body, returning the main working tree itself. Same docstring idea, same UserError.
   - `repository_board_directory(starts)` becomes `return repository_root(starts) / DEFAULT_BOARD_SUBDIR`.
   - `board_directory()` uses `discovery_starts()`.
   - `SKILL_DOCUMENT` (line 2164) becomes `SCRIPT_FILE.parent.parent / "SKILL.md"`.
4. **New functions, right after `board_directory()`,** in this order:
   - `live_board_repository(directory: Path) -> Optional[Path]`: the repository whose own board `directory` is, or None. Discover from `discovery_starts()`. A UserError from discovery gives None, because `TEXTMOUTH_BBS_DIR` may name a board outside every repository. Compare `(root / DEFAULT_BOARD_SUBDIR).resolve()` with `directory.resolve()`.
   - `run_git(repository: Path, *args: str, stdin: str = "") -> Optional[str]`: run `git` with `cwd=repository`, `input=stdin`, `capture_output=True`, `text=True`, and `timeout=GIT_TIMEOUT_SECONDS`. Return its standard output. Return None when git is missing or cannot start (OSError), times out (`subprocess.TimeoutExpired`), or exits non-zero.
   - `script_is_unmerged(repository: Path, script: Path = SCRIPT_FILE) -> bool`: True only when git shows that main has never had this content. Each `None` below means git cannot tell, so the answer is False.
     1. `run_git(repository, "hash-object", f"--path={SCRIPT_PATH_IN_REPOSITORY}", "--", str(script))` gives the copy's blob id. With `--path`, git applies the repository's attributes exactly as `git add` would, even for a copy outside the repository.
     2. **The usual case, in one call:** `run_git(repository, "rev-parse", "--verify", "--quiet", f"{REFERENCE_BRANCH}:{SCRIPT_PATH_IN_REPOSITORY}")`. Equal to the copy's id gives False. A None here only means there is no quick answer, so go on.
     3. `run_git(repository, "rev-list", REFERENCE_BRANCH, "--", SCRIPT_PATH_IN_REPOSITORY)` lists main's commits that changed the script. It exits 128 when there is no main branch: None means cannot tell, so False.
     4. `run_git(repository, "cat-file", "--batch-check=%(objectname)", stdin=...)`, with one line `<commit>:<path>\n` per commit, gives the script's blob id at each.
     5. Return whether the copy's id is missing from that set. If main never had the script at all, the set is empty and the copy is unmerged.
   - `guard_live_board(directory: Path) -> None`: raise `UserError` when an unmerged copy is about to open the live board. Check in order of cost:
     1. `ALLOW_UNMERGED_ENV` set (stripped) to anything but `""` or `"0"` returns.
     2. `live_board_repository(directory)` of None returns.
     3. `script_is_unmerged(repository)` raises with exactly this text, which `report_error` prints as one line:

            f"this copy of {PROG} has changes that are not on main, so it will not open the live board in {directory}; to try it, set {BOARD_DIR_ENV} to a scratch folder, and use main's copy of the script for the live board"

        Do not mention `ALLOW_UNMERGED_ENV` in the message: the way out for a worker is a scratch board, never the override.
5. **`open_board()`** (lines 784-810): call `guard_live_board(directory)` right after `directory = board_directory()` and before `mkdir`, so that a refused copy creates nothing. Add one sentence at the end of its docstring. Leave its first docstring line and everything above `def open_board` alone: another worker appends to `SCHEMA_ADDITIONS` just above it.
6. **The module docstring** (lines 1-22): after the two location bullets (line 15), add one short paragraph. "A copy of this script that main has never had, such as one with uncommitted edits or unmerged commits, refuses to open the repository's own board; point TEXTMOUTH_BBS_DIR at a scratch folder to try it."

## Tests (test_bbs.py)
- **`RepositoryDiscoveryTests.test_a_linked_worktree_uses_the_main_repository_board`** (lines 1650-1683) runs this repository's script in a temporary repository. After `env = environment_without_board_override()`, set `env[bbs.ALLOW_UNMERGED_ENV] = "1"`. Comment why: the test is about discovery, and this script is foreign to the temporary repository. Today it passes only because git's built-in default branch is `master`, which leaves the guard unable to tell.
- **A new class `LiveBoardGuardTests(TemporaryDirectoryTestCase)`,** placed immediately *before* `class RepositoryDiscoveryTests` (line 1647), with `@unittest.skipUnless(shutil.which("git"), "git is not installed")` on the class. Reuse the file's `git(...)` and `git_environment()` helpers (lines 78-89).
  - **Helpers,** each with a docstring:
    - `make_repository(branch="main") -> Path`: `git("init", "-q", "-b", branch, cwd=repo)` in a temp dir, copy `SCRIPT` to `repo / bbs.SCRIPT_PATH_IN_REPOSITORY` (make the folders), `git add` it, and commit.
    - `edit(script: Path)`: append a comment line that main has never had.
    - `run_copy(script: Path, cwd: Path, **env_changes) -> subprocess.CompletedProcess`: runs `[sys.executable, str(script), "agents", "--json"]` with timeout 60. Its env is `git_environment()` without `BOARD_DIR_ENV` and `ALLOW_UNMERGED_ENV`, then updated with `env_changes`.
    - **Safety:** `run_copy` must first assert that `script` is not `SCRIPT`, and that `cwd` lies inside the system temp folder (`Path(tempfile.gettempdir()).resolve()`). Then no test can ever reach this repository's live board.
  - **A refusal check:** exit status 1, empty stdout, and stderr exactly `"bbs.py: error: " + <the message above> + "\n"`, with the live board folder `repo/.claude/agent-bbs` absent afterwards.
  - **Tests:**
    1. `test_a_copy_main_has_opens_the_live_board`: the committed copy, run from the repository, exits 0 and prints `[]`, and `repo/.claude/agent-bbs/board.sqlite` exists.
    2. `test_an_edited_copy_is_refused_before_it_creates_anything`: an uncommitted edit is refused.
    3. `test_a_commit_on_another_branch_is_refused_until_main_merges_it`: `checkout -q -b side`, then edit and commit, is refused. Then `checkout -q main` and `merge -q --no-ff side -m "Merge side"`, and the copy opens the live board.
    4. `test_an_older_copy_from_mains_history_still_opens_the_live_board`: copy the committed script to a temp folder outside the repository (v1). Edit and commit on main (v2). Run the outside v1 copy with `cwd` in the repository: it exits 0. An outside copy with an edit main never had is refused.
    5. `test_a_scratch_board_skips_the_check`: an edited copy with `TEXTMOUTH_BBS_DIR` set to a temp folder exits 0. The scratch board exists, and the live one does not.
    6. `test_naming_the_live_board_in_the_variable_is_still_checked`: an edited copy with `TEXTMOUTH_BBS_DIR=str(repo / ".claude" / "agent-bbs")` is refused.
    7. `test_the_allow_variable_lets_an_unmerged_copy_through`: an edited copy with the variable at `"1"` exits 0, and with `"0"` is refused.
    8. `test_without_a_main_branch_the_guard_lets_the_copy_through`: `make_repository(branch="trunk")`, then an edit, exits 0.
    9. `test_when_git_fails_the_guard_lets_the_copy_through`: in-process. With `mock.patch.object(bbs.subprocess, "run", side_effect=FileNotFoundError("git"))`, `bbs.script_is_unmerged(repo, edited_copy)` is False. The same holds with `side_effect=subprocess.TimeoutExpired("git", 10)`.
    10. `test_live_board_repository_names_only_the_discovered_board`: in-process, with `mock.patch.object(bbs, "discovery_starts", return_value=[repo])`. `live_board_repository(repo / ".claude" / "agent-bbs")` is `repo`, and a temp scratch folder gives None.
    11. `test_the_script_path_constant_names_this_file`: `SCRIPT.relative_to(SKILL_DIR.parents[2]).as_posix() == bbs.SCRIPT_PATH_IN_REPOSITORY`.

## SKILL.md
In "Where the board lives" (lines 124-128), add this paragraph between the paragraph ending "...tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`." and "The teams tables are additions.":

> A guard keeps changed copies of the script off the live board. Before the script opens the repository's own board, it asks git whether its own file is a version of `.claude/skills/agent-bbs/scripts/bbs.py` that `main` has had. A copy with uncommitted edits, or with commits not yet merged into `main`, is refused with a one-line error and creates nothing. Every copy `main` has had, older or newer, keeps working. A board named by `TEXTMOUTH_BBS_DIR` is not checked, unless it is the live board's own folder. When git cannot tell, because it is missing or the repository has no `main` branch, the script goes ahead. To try a changed copy, point `TEXTMOUTH_BBS_DIR` at a scratch folder, and use main's copy for the live board. After reviewing a change, the orchestrator may let an unmerged copy through with `TEXTMOUTH_BBS_ALLOW_UNMERGED=1`.

## Commits
1. "Split the board's repository discovery into reusable steps": the refactor in item 3, with no change in behavior.
2. "Keep copies of the board script that main has never had off the live board": everything else, with the tests and SKILL.md.

## Completion check
- `grep -n "Path(__file__)" .claude/skills/agent-bbs/scripts/bbs.py` finds only the `SCRIPT_FILE` line.
- `grep -n "Path.cwd()" .claude/skills/agent-bbs/scripts/bbs.py` finds only `discovery_starts`.

## Not yours
- `SCHEMA_ADDITIONS` and the lines between it and `def open_board`.
- `cmd_register`, and the team and task functions.
- `build_parser`.
- Every test class but `RepositoryDiscoveryTests` and your new one.
- SKILL.md outside "Where the board lives".
