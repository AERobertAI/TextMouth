"""repo_paths.py: where the main checkout is, and where Claude Code keeps its files for it.

The tools in Scripts/ share state that lives in the repository's main checkout and
nowhere else: the heavy-work lock, the build train's queue and results, the message
board, and `build/orchestrator/`. A tool run from an agent's worktree, or from a copy
of this repository, must still reach that one place. A path written into a script
would tie it to one Mac, and the folder a script is in is the worktree's, not the main
checkout's. So `main_checkout()` asks git, which knows: the common git directory of
a worktree is the main checkout's own `.git` folder, and the main checkout is its
parent.

`claude_project_dir()` names the folder where Claude Code keeps this project's session
transcripts. Claude Code derives its name from the main checkout's path, so the name is
computed here and written nowhere.

Tools import this module by path, because `python3 -I` leaves a script's own folder out
of sys.path. The way to import it from a script in Scripts/agents:

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

and from a script elsewhere, with the path of Scripts/agents in place of the folder.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# The folder this module is in: Scripts/agents of whichever checkout or worktree holds it.
HERE = Path(__file__).resolve().parent

# How long git may take to answer `rev-parse`, in seconds. It answers in milliseconds.
GIT_TIMEOUT_SECONDS = 30

# The variables that point git at a repository other than the folder it is run in.
# A tool run from inside a git hook inherits them, and they would hide the answer.
GIT_LOCATION_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX")


class MainCheckoutNotFound(RuntimeError):
    """The folder is not inside a git repository, so no main checkout can be named."""


def _git_environment():
    """The environment git is run in: this process's, less the variables that redirect git."""
    return {name: value for name, value in os.environ.items() if name not in GIT_LOCATION_VARIABLES}


def main_checkout(start=None):
    """The main checkout of the repository that `start` (a folder, or a file in one) is in.

    `start` defaults to this module's own folder, which is in the same checkout or
    worktree as the tool that imports it. A linked worktree's common git directory
    is the main checkout's `.git`, so the answer is the same from every worktree.
    The path is absolute and has no symbolic links, as git prints it.
    Raises MainCheckoutNotFound when `start` is not in a git repository.
    """
    folder = Path(start) if start is not None else HERE
    if not folder.is_dir():
        folder = folder.parent
    try:
        result = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                cwd=folder, capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS,
                                env=_git_environment())
    except (OSError, subprocess.SubprocessError) as error:
        raise MainCheckoutNotFound(f"git could not be run in {folder}: {error}") from error
    common = result.stdout.strip()
    if result.returncode != 0 or not common:
        raise MainCheckoutNotFound(f"{folder} is not inside a git repository: {result.stderr.strip()}")
    # The common directory is "<main checkout>/.git"; the main checkout is its parent.
    return Path(common).parent


def claude_home():
    """Claude Code's folder in the user's home folder (`~/.claude`)."""
    return Path.home() / ".claude"


def claude_project_folder_name(checkout=None):
    """The name Claude Code gives a project's folder under `~/.claude/projects`.

    It is the checkout's path with every character that is not a letter or a digit
    changed to a hyphen, so the slashes (and the dots of `.claude`) all become hyphens.
    `checkout` defaults to the main checkout.
    """
    path = main_checkout() if checkout is None else Path(checkout)
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def claude_project_dir(checkout=None):
    """The folder where Claude Code keeps the session transcripts of the project at `checkout`
    (the main checkout by default): `~/.claude/projects/<folder name>`."""
    return claude_home() / "projects" / claude_project_folder_name(checkout)


def claude_usage_script():
    """The path of the claude-usage-left skill's script, which reports the subscription's usage windows."""
    return claude_home() / "skills" / "claude-usage-left" / "scripts" / "claude_usage.py"
