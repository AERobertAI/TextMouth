"""``affected [REF]``: the sections of the docs that a branch's changes touch.

    python3 -I .claude/skills/doc-library/scripts/doclib.py affected
    python3 -I .claude/skills/doc-library/scripts/doclib.py affected doclib/paths --base team/doclib
    python3 -I .claude/skills/doc-library/scripts/doclib.py affected M --base M^1

The changes are what ``git diff --name-status -M BASE...REF`` reports: the branch's
own changes since it met BASE (``main`` by default; REF is ``HEAD`` by default). For
the merge commit M of an old branch, ``affected M --base M^1`` gives what the merge
brought. Markdown files are skipped: they are the docs themselves.

For each changed file, in path order, each section with a citation that names it
(the same rule as ``where``) is one hit: ``STATUS FILE: the citing line``. A renamed
file is looked for under its old and its new name. After the hits come the changed
Swift files that no section cites, one ``uncited: FILE`` line each (never capped),
and a summary on standard error. The docs read are the working tree's, whatever REF
is. Exit status 0 when there was a hit, 1 when there was none, 2 for a bad ref or a
folder that is not a git repository.
"""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Tuple

import citations
import docmodel
import output
from citations import Citation
from cmd_where import citation_hit
from sectionrefs import section_citations
from docmodel import Page, Section
from output import Hit, UsageError
from repofiles import RepoFiles

# The ref a branch is measured from, and the ref measured, when none is given.
DEFAULT_BASE = "main"
DEFAULT_REF = "HEAD"


@dataclass
class Change:
    """One changed file as git reports it.

    ``status`` is ``A``, ``M``, ``D``, ``T`` or ``R``; ``path`` the file now (the old
    one for a deletion); ``old`` the file's name before a rename, else ``None``.
    """

    status: str
    path: str
    old: str = ""

    @property
    def names(self) -> List[str]:
        """The paths a doc might cite the file by: the old name first, when renamed."""
        return [self.old, self.path] if self.old else [self.path]

    @property
    def is_swift_file(self) -> bool:
        """True for a Swift file that still exists after the change."""
        return self.status != "D" and self.path.endswith(".swift")


def check_ref(ref: str, what: str) -> None:
    """A UsageError when ``ref`` is empty or could be taken by git for an option."""
    if not ref or ref.startswith("-"):
        raise UsageError(f"{what} {ref!r} is not a git ref")


def parse_name_status(data: bytes) -> List[Change]:
    """The changes in the output of ``git diff --name-status -z``.

    The output is ``STATUS NUL PATH NUL``, and ``STATUS NUL OLD NUL NEW NUL`` for a
    rename or copy (whose status carries a score, as in ``R087``).
    """
    fields = data.decode("utf-8", errors="surrogateescape").split("\0")
    changes: List[Change] = []
    index = 0
    while index < len(fields) and fields[index]:
        status = fields[index][0]
        if status in "RC":
            changes.append(Change(status, fields[index + 2], fields[index + 1]))
            index += 3
        else:
            changes.append(Change(status, fields[index + 1]))
            index += 2
    return changes


def changed_files(root: Path, base: str, ref: str) -> List[Change]:
    """The changes of ``BASE...REF`` in the repository at ``root``, Markdown files left out.

    A UsageError carries git's own message for an unknown ref, and says so when
    ``root`` is not a git repository.
    """
    if not (root / ".git").exists():
        raise UsageError(f"{root} is not a git repository")
    check_ref(base, "--base")
    check_ref(ref, "REF")
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "diff", "--name-status", "-z", "-M", f"{base}...{ref}"],
            capture_output=True, check=False)
    except OSError as error:
        raise UsageError(f"git could not run: {error}") from None
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip().splitlines()
        raise UsageError(message[0] if message else f"git diff {base}...{ref} failed")
    return [change for change in parse_name_status(result.stdout) if not change.path.endswith(".md")]


def cited_sections(root: Path, scope: str, repo: RepoFiles) -> List[Tuple[Page, Section, List[Citation]]]:
    """Every section of the scope that cites anything, with its citations, in scope order."""
    found = []
    for path in docmodel.scope_pages(root, scope):
        page = docmodel.load_page(root, path)
        for section in page.sections:
            cited = section_citations(page, section, repo)
            if cited:
                found.append((page, section, cited))
    return found


def change_hits(change: Change, sections: List[Tuple[Page, Section, List[Citation]]]) -> Iterator[Hit]:
    """The hits for one change: for each of its names, each section citing it, at the first such citation."""
    for name in change.names:
        prefix = f"{change.status} {name}: "
        for page, section, cited in sections:
            for citation in cited:
                if citations.names_path(citation, name, name):
                    hit = citation_hit(page, section, citation, prefix)
                    hit.extra.update({"changed": name, "status": change.status})
                    yield hit
                    break


def summary_line(changes: List[Change], cited: Dict[str, bool]) -> str:
    """The standard-error summary: how many files changed, and how many Swift ones are cited."""
    swift = [change for change in changes if change.is_swift_file]
    cited_count = sum(1 for change in swift if cited[change.path])
    percent = f"{int(100 * cited_count / len(swift) + 0.5)}" if swift else "-"
    return (f"doclib: {len(changes)} files changed; {len(swift)} Swift, {cited_count} of them cited "
            f"({percent}%); {len(swift) - cited_count} uncited")


def run(args: Any) -> int:
    """Print the sections the changes touch, then the uncited Swift files; 0 when there was a hit."""
    changes = sorted(changed_files(args.root, args.base, args.ref), key=lambda change: change.path)
    repo = RepoFiles.load(args.root)
    sections = cited_sections(args.root, args.scope, repo)
    # Which changes at least one section cites, filled in as the hits are made.
    cited: Dict[str, bool] = {change.path: False for change in changes}

    def all_hits() -> Iterator[Hit]:
        """The hits of every change, in path order, noting which changes were cited."""
        for change in changes:
            for hit in change_hits(change, sections):
                cited[change.path] = True
                yield hit

    total = output.emit(all_hits(), args, noun="hits")
    # The uncited Swift files are never capped.
    for change in changes:
        if change.is_swift_file and not cited[change.path]:
            if args.json:
                print(json.dumps({"uncited": change.path}, ensure_ascii=False))
            else:
                print(f"uncited: {change.path}")
    print(summary_line(changes, cited), file=sys.stderr)
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``affected`` subcommand."""
    parser = subparsers.add_parser(
        "affected", parents=[common], help="the sections a branch's changes touch, and the uncited Swift files",
        description="List the sections of the docs that cite the files a branch changed, "
                    "and the changed Swift files that no section cites.")
    parser.add_argument("ref", metavar="REF", nargs="?", default=DEFAULT_REF,
                        help=f"the branch or commit whose changes are read (default {DEFAULT_REF})")
    parser.add_argument("--base", default=DEFAULT_BASE, metavar="BASE",
                        help=f"the ref REF is compared with since the two met (default {DEFAULT_BASE})")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
