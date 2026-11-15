"""The repository's files as git sees them, and how a path written in a doc resolves.

``RepoFiles`` decides whether a path exists only from the list of files it was
given (``load`` makes that list once, with git), so it never touches a path
outside the repository folder: asking about ``~/.TextMouth/library.json`` or
``/Library/Caches/x`` is answered from the list, and ``is_repo_path`` refuses such
tokens before anything else.
"""

from __future__ import annotations

import bisect
import os
import re
import subprocess
from pathlib import Path
from typing import Dict, FrozenSet, Iterable, List

import output

# The extensions of the source files a doc may cite by bare name (``Parser.swift``).
SOURCE_EXTENSIONS = frozenset({"swift", "py", "sh", "h", "c", "m", "mm", "js"})

# Folders the plain-folder walk (used where there is no git) never enters.
SKIPPED_FOLDERS = frozenset({"build", "DerivedData"})

# Where the app's own code lives; a doc may name a path under it without the prefix.
APP_FOLDER = "TextMouth"

# White space, or a character that makes a token a glob, a placeholder, or a shell word.
_NOT_A_PATH = re.compile(r"[\s<>*?$\[\]{}|\\]")


class RepoFiles:
    """The files of one repository (or worktree) and the paths docs write for them.

    ``files``: the repository-relative POSIX paths of its files.
    ``dirs``: every folder that holds one of them, at any depth, with no trailing slash.
    ``tops``: the names at the root, plus the names directly under ``TextMouth/``.
    """

    def __init__(self, root: Path, files: Iterable[str]) -> None:
        """Index ``files`` (repository-relative POSIX paths); ``root`` is only remembered."""
        self.root = root
        self.files: FrozenSet[str] = frozenset(files)
        # A sorted copy, for prefix lookups in ``under``.
        self._sorted = sorted(self.files)
        dirs = set()
        tops = set()
        self._by_name: Dict[str, List[str]] = {}
        for path in self._sorted:
            parts = path.split("/")
            # Every ancestor folder of the file.
            for depth in range(1, len(parts)):
                dirs.add("/".join(parts[:depth]))
            tops.add(parts[0])
            if parts[0] == APP_FOLDER and len(parts) > 1:
                tops.add(parts[1])
            self._by_name.setdefault(parts[-1], []).append(path)
        self.dirs: FrozenSet[str] = frozenset(dirs)
        self.tops: FrozenSet[str] = frozenset(tops)

    @classmethod
    def load(cls, root: Path) -> "RepoFiles":
        """The files under ``root``: from git when ``root`` has a ``.git``, else a walk.

        With git, the files are the tracked and the untracked-but-not-ignored ones,
        minus any deleted from the working tree: two git commands, and no look at
        the listed paths themselves. Without it (a test's plain folder) the walk
        skips hidden folders, ``build/`` and ``DerivedData/`` and follows no symlink.
        """
        if (root / ".git").exists():
            listed = cls._git_lines(root, "--cached", "--others", "--exclude-standard")
            deleted = set(cls._git_lines(root, "--deleted"))
            return cls(root, [path for path in listed if path not in deleted])
        return cls(root, cls._walk(root))

    @staticmethod
    def _git_lines(root: Path, *options: str) -> List[str]:
        """The paths ``git ls-files -z OPTIONS`` prints for ``root``."""
        try:
            result = subprocess.run(
                ["git", "-C", str(root), "ls-files", "-z", *options],
                capture_output=True, check=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise output.UsageError(f"git could not list the files of {root}: {error}") from None
        # surrogateescape keeps an undecodable name distinct instead of failing.
        text = result.stdout.decode("utf-8", errors="surrogateescape")
        return [path for path in text.split("\0") if path]

    @staticmethod
    def _walk(root: Path) -> List[str]:
        """Every file under ``root`` as a relative POSIX path, outside skipped folders."""
        found: List[str] = []
        for folder, names, files in os.walk(root, followlinks=False):
            # Pruning ``names`` in place keeps os.walk out of those folders.
            names[:] = [name for name in names if not name.startswith(".") and name not in SKIPPED_FOLDERS]
            relative = Path(folder).relative_to(root).as_posix()
            prefix = "" if relative == "." else relative + "/"
            found.extend(prefix + name for name in files)
        return found

    def is_file(self, path: str) -> bool:
        """True when ``path`` is one of the repository's files."""
        return path in self.files

    def is_dir(self, path: str) -> bool:
        """True when ``path`` (with or without a trailing slash) is a folder holding a file."""
        return path.rstrip("/") in self.dirs

    def by_name(self, name: str) -> List[str]:
        """The files whose last component is ``name``, sorted."""
        return list(self._by_name.get(name, ()))

    def under(self, folder: str) -> List[str]:
        """The files inside ``folder`` (with or without a trailing slash), sorted."""
        stripped = folder.strip("/")
        prefix = stripped + "/" if stripped else ""
        # Sorted order puts every path with the prefix in one run.
        first = bisect.bisect_left(self._sorted, prefix)
        found = []
        for path in self._sorted[first:]:
            if not path.startswith(prefix):
                break
            found.append(path)
        return found

    def is_repo_path(self, token: str) -> bool:
        """Whether ``token``, as written in a doc, is meant as a repository path.

        This is only a syntactic test; ``resolve`` finds what it names. A glob, a
        placeholder, an absolute or home or ``../`` path, a URL, and a path whose
        first folder is not one of the repository's (a data-directory path such as
        ``Logs/textmouth.log``) are not. A bare name must be a file at the root or
        a source file's name.
        """
        if not token or _NOT_A_PATH.search(token):
            return False
        if token.startswith(("/", "~", "../")) or "//" in token or "://" in token:
            return False
        if ".." in token.split("/"):
            return False
        if "/" in token:
            return token.split("/", 1)[0] in self.tops
        # A bare name: a file at the root (``project.yml``, ``Makefile``), which the
        # architecture pages' Files: lists name, or a source file's name, which may
        # live anywhere (``DOCXParser+Numbering.swift``).
        if self.is_file(token):
            return True
        stem, dot, extension = token.rpartition(".")
        return bool(stem) and bool(dot) and extension in SOURCE_EXTENSIONS

    def resolve(self, token: str) -> List[str]:
        """The existing paths ``token`` names, sorted; empty when it names nothing.

        A path is looked for from the root, then under ``TextMouth/``. One that
        names a folder resolves to the folder with a trailing slash. A bare name
        is the root's file of that name when there is one, else every file with
        that name.
        """
        if not self.is_repo_path(token):
            return []
        if "/" not in token:
            return [token] if self.is_file(token) else self.by_name(token)
        wants_folder = token.endswith("/")
        stripped = token.rstrip("/")
        for candidate in (stripped, f"{APP_FOLDER}/{stripped}"):
            if not wants_folder and self.is_file(candidate):
                return [candidate]
            if self.is_dir(candidate):
                return [candidate + "/"]
        return []

    @staticmethod
    def covers(cited: str, path: str) -> bool:
        """True when ``cited`` is ``path``, or is a folder (ending in ``/``) holding it."""
        return cited == path or (cited.endswith("/") and path.startswith(cited))
