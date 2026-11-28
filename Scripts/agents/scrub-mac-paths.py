#!/usr/bin/env python3
"""scrub-mac-paths.py: keeps the paths that belong to one Mac out of the tracked files.

The repository is public. A path such as the home folder, the repository's location
under it, Claude Code's session folders, or the temporary folder says whose Mac
the files were written on. This script finds those paths and, unless asked only to
check, rewrites them in place:

    the main checkout, and its `~` form           ->  <main checkout>
    a Claude Code session folder                  ->  <session folder>
    Claude Code's project folder name             ->  <project folder>
    the temporary folder ($TMPDIR)                ->  $TMPDIR
    the folder of the main checkout's projects    ->  ~/…
    any other path under the home folder          ->  ~/…

Every value is computed when the script runs, from the home folder, git, `$TMPDIR`, and the user ID,
so no commit holds them. Run it from any checkout or worktree of the repository:

    python3 -I -B Scripts/agents/scrub-mac-paths.py --check            # counts by kind; exits 1 if any is found
    python3 -I -B Scripts/agents/scrub-mac-paths.py                    # rewrites the tracked files in place
    python3 -I -B Scripts/agents/scrub-mac-paths.py PATHSPEC ...       # only the tracked files under the pathspecs
    python3 -I -B Scripts/agents/scrub-mac-paths.py --check --list     # also names every file

It reads the tracked files only (`git ls-files`), skips binary files and links, and writes only a file
whose text changed, with its bytes otherwise as they were. It deletes nothing. Ignored and untracked files are
not in the repository, so it leaves them alone.

`--check` also reports the paths of any other account under /Users, /private/tmp/claude-*, and /var/folders
that it cannot rewrite by name: a made-up fixture such as /Users/reader is allowed (FIXTURE_ACCOUNTS), the rest
is a real person's. The policy test (tests/test_no_mac_paths.py) runs the same check on every push.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# repo_paths.py is beside this script; python3 -I leaves its folder out of sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

# The account names of made-up paths in tests and docs, and of GitHub's runner: not anyone's real home.
# "Shared" is macOS's own shared folder.
FIXTURE_ACCOUNTS = frozenset({"reader", "x", "someone", "somebody", "me", "you", "nobody", "runner", "Shared"})

# The names of the kinds of path, in the order the report prints them.
SESSION, PROJECT, REPOSITORY, TEMP, HOME = ("session folder", "project folder name", "repository location",
                                            "temporary folder", "other path under the home folder")
KINDS = (SESSION, PROJECT, REPOSITORY, TEMP, HOME)
# The kind of path that names a real account but cannot be rewritten by name.
OTHER = "another account's path"

# What may follow a name for the name to be the whole name: not a letter, a digit, an underscore, or a hyphen.
WHOLE = r"(?![A-Za-z0-9_-])"
# What may stand before a Claude session folder's UUID.
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

# The paths of other accounts that cannot be rewritten by name, and so only reported. Each is (pattern, which
# group holds the account name, or None when any match counts).
GENERIC = (
    # /Users/<name>, however it continues. A placeholder such as /Users/<you> has a character the name cannot hold.
    (re.compile(r"(?<![A-Za-z0-9_])/Users/([A-Za-z0-9._-]+)"), 1),
    # Claude Code's project folder name: -Users-<name>-<the rest of the path>.
    (re.compile(r"(?<![A-Za-z0-9])-Users-([A-Za-z0-9]+)-"), 1),
    # Claude Code's session folders: /private/tmp/claude-<user ID>/...
    (re.compile(r"/tmp/claude-[0-9]+/"), None),
    # A user's temporary folder: /var/folders/<2 characters>/<a long ID>. The fixtures' are short (/var/folders/zz/T).
    (re.compile(r"/var/folders/[A-Za-z0-9_]{2}/[A-Za-z0-9_]{20,}"), None),
)


class Machine:
    """What belongs to this Mac: its home folder, the main checkout, the temporary folder, and the user ID."""

    def __init__(self, home, main, tmpdir=None, uid=None):
        self.home = str(home).rstrip("/")
        self.main = str(main).rstrip("/")
        self.tmpdir = str(tmpdir).rstrip("/") if tmpdir else None
        self.uid = uid

    @classmethod
    def detect(cls):
        """The machine this script is running on."""
        return cls(Path.home(), repo_paths.main_checkout(), os.environ.get("TMPDIR"), os.getuid())

    @property
    def is_fixture(self):
        """True when the home folder is a made-up one (a test's, or GitHub's runner), whose paths are not secret."""
        return Path(self.home).name in FIXTURE_ACCOUNTS

    def names(self):
        """The strings that name this Mac's owner or place wherever they stand, not only in a path.

        These are the account name, the temporary folder's long ID, and the checkout's place below the home folder.
        None are returned for a made-up home folder (nothing there is secret). The account name counts only when
        it is long enough (5 letters) not to match ordinary words.
        """
        if self.is_fixture:
            return []
        names = []
        account = Path(self.home).name
        if len(account) >= 5:
            names.append(account)
        if self.tmpdir:
            # /var/folders/<xx>/<ID>/T: the ID is the second last part.
            parts = Path(self.tmpdir).parts
            if len(parts) >= 2 and len(parts[-2]) >= 20:
                names.append(parts[-2])
        relative = self.repository_relative()
        if relative and len(Path(relative).parts) > 1:
            names.append(relative)
        return names

    def repository_relative(self):
        """The main checkout's path below the home folder ('a/b/TextMouth'), or None when it is not under it."""
        try:
            return Path(self.main).relative_to(self.home).as_posix()
        except ValueError:
            return None


def under_home(machine, relative):
    """A pattern for a path `relative` to the home folder, written in full, with `~`, or with $HOME."""
    prefix = "|".join(re.escape(form) for form in (machine.home, "~", "$HOME", "${HOME}"))
    return f"(?:{prefix})/{re.escape(relative)}"


def rules_for(machine):
    """The rewrite rules for `machine`: a list of (kind, compiled pattern, replacement), in the order to apply.

    The longer, more specific paths come first, so the home folder's rule only sees what is left. A made-up home
    folder (a test's, or GitHub's runner) gets no rule for the home folder or the checkout, since its paths are
    fixtures. The temporary folder's and the sessions' rules apply anywhere.
    """
    rules = [
        # /private/tmp/claude-<uid>/-Users-<name>-<path>/<session UUID>, with its /private prefix or without.
        (SESSION, re.compile(rf"(?:/private)?/tmp/claude-[0-9]+/-[A-Za-z0-9-]+/{UUID}"), "<session folder>"),
    ]
    if not machine.is_fixture:
        # Claude Code's folder name for the main checkout: its path with every other character a hyphen.
        project = re.sub(r"[^A-Za-z0-9]", "-", machine.main)
        rules.append((PROJECT, re.compile(re.escape(project) + WHOLE), "<project folder>"))
        # The main checkout, in full, with `~`, or with $HOME.
        relative = machine.repository_relative()
        full = re.escape(machine.main)
        pattern = f"(?:{full}|{under_home(machine, relative)})" if relative else full
        rules.append((REPOSITORY, re.compile(pattern + WHOLE), "<main checkout>"))
        # The folder that holds the main checkout's own folder's neighbours, such as a scratch project beside it.
        if relative and len(Path(relative).parents) > 2:
            projects = Path(relative).parent.parent.as_posix()
            rules.append((HOME, re.compile(under_home(machine, projects) + "/"), "~/…/"))
    if machine.tmpdir:
        # $TMPDIR, as /var/folders/<xx>/<id>/T, and as its /private/var/... real path.
        rules.append((TEMP, re.compile(r"(?:/private)?" + re.escape(re.sub(r"^/private", "", machine.tmpdir)) + WHOLE),
                      "$TMPDIR"))
    if not machine.is_fixture:
        rules.append((HOME, re.compile(re.escape(machine.home) + WHOLE), "~"))
    return rules


def scrub_text(text, rules):
    """Applies `rules` to `text`. Returns the new text and a Counter of how many paths of each kind it rewrote.

    The rules apply one after another, the most specific first, and each path counts once, under the first rule
    that took it: the repository's location is under the home folder, but counts as the repository's. What the
    home folder's rule counts is every other path under it.
    """
    counts = collections.Counter()
    for kind, pattern, replacement in rules:
        text, n = pattern.subn(replacement, text)
        counts[kind] += n
    return text, +counts


def other_accounts_paths(text):
    """The paths in `text` that name a real account (or session or temporary folder) not on this Mac's rules.

    A made-up account's paths (FIXTURE_ACCOUNTS) are left out. Returns the matched strings.
    """
    found = []
    for pattern, group in GENERIC:
        for match in pattern.finditer(text):
            if group is None or match.group(group) not in FIXTURE_ACCOUNTS:
                found.append(match.group(0))
    return found


def tracked_files(root, pathspecs):
    """The tracked files of the repository at `root`, under `pathspecs` when given, as paths relative to it."""
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *pathspecs], capture_output=True,
                            check=True, timeout=60)
    return [name.decode("utf-8", "surrogateescape") for name in result.stdout.split(b"\0") if name]


def read_text(path):
    """A file's text, decoded so that every byte survives a round trip; None for a link, a binary file, or no file."""
    if path.is_symlink() or not path.is_file():
        return None
    data = path.read_bytes()
    if b"\0" in data:
        return None
    return data.decode("utf-8", "surrogateescape")


def scan(root, machine, pathspecs=(), write=False):
    """Scans the tracked files under `root`; with `write`, rewrites those that hold this Mac's paths.

    Returns (counts, files, others, leaks): counts maps each kind to how many paths were found, `files` maps each
    kind to the set of files holding them, `others` maps a file to the other accounts' paths it holds, and `leaks`
    maps a file to this Mac's names (Machine.names) it holds outside a path, both as the text is after any rewrite.
    Only a file whose text changed is written.
    """
    rules = rules_for(machine)
    counts = collections.Counter()
    files = collections.defaultdict(set)
    others = {}
    leaks = {}
    names = machine.names()
    for name in tracked_files(root, pathspecs):
        path = Path(root) / name
        text = read_text(path)
        if text is None:
            continue
        new_text, found = scrub_text(text, rules)
        for kind, n in found.items():
            counts[kind] += n
            files[kind].add(name)
        if write and new_text != text:
            path.write_bytes(new_text.encode("utf-8", "surrogateescape"))
        strangers = other_accounts_paths(new_text)
        if strangers:
            others[name] = strangers
        held = [value for value in names if value in new_text]
        if held:
            leaks[name] = held
    return counts, files, others, leaks


def report(counts, files, others, leaks, listing=False, out=sys.stdout):
    """Prints the counts by kind (paths, and files holding them), then the paths of other accounts and this Mac's
    names that no rule rewrites. Returns the total found."""
    total = 0
    for kind in KINDS:
        print(f"{kind}: {counts[kind]} paths in {len(files[kind])} files", file=out)
        total += counts[kind]
        if listing:
            for name in sorted(files[kind]):
                print(f"    {name}", file=out)
    print(f"{OTHER}: {sum(len(found) for found in others.values())} paths in {len(others)} files", file=out)
    total += sum(len(found) for found in others.values())
    for name in sorted(others):
        # An unrewritable path is always listed, so a person can fix it by hand.
        print(f"    {name}: {', '.join(sorted(set(others[name])))}", file=out)
    print(f"this Mac's names outside a path: {sum(len(found) for found in leaks.values())} in {len(leaks)} files",
          file=out)
    total += sum(len(found) for found in leaks.values())
    for name in sorted(leaks):
        # The name itself is not printed, since this output may be copied into a commit message or a report.
        print(f"    {name}: {len(leaks[name])} name(s) of this Mac", file=out)
    return total


def main(argv=None, machine=None, root=None, out=sys.stdout):
    """Runs the script. `machine` and `root` are for tests; by default this Mac and this script's own checkout.

    With --check, changes nothing and returns 1 when any path is found. Otherwise rewrites the files, prints what it
    changed, and returns 1 only when something remains that it cannot rewrite (another account's path, or one of
    this Mac's names outside a path).
    """
    parser = argparse.ArgumentParser(prog="scrub-mac-paths.py", description=__doc__.splitlines()[0])
    parser.add_argument("pathspecs", nargs="*", help="only the tracked files under these paths (default: all)")
    parser.add_argument("--check", action="store_true", help="change nothing; exit 1 if any path is found")
    parser.add_argument("--list", action="store_true", help="also name each file that holds a path")
    args = parser.parse_args(argv)
    machine = machine or Machine.detect()
    root = Path(root) if root else Path(repo_paths.HERE).parent.parent
    counts, files, others, leaks = scan(root, machine, args.pathspecs, write=not args.check)
    total = report(counts, files, others, leaks, args.list, out)
    if args.check:
        print("found" if total else "clean", file=out)
        return 1 if total else 0
    # After a rewrite, only paths that could not be rewritten by name remain.
    remaining = sum(len(found) for found in others.values()) + sum(len(found) for found in leaks.values())
    print("rewritten; left for a person: %d" % remaining, file=out)
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
