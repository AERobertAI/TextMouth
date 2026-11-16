"""heavy_lock.py: one heavy job at a time on this Mac, machine-wide.

The Mac has 8 GB of memory, and on October 31, 2026 it froze under several
builds at once. The build train (build-train.py) already runs one Xcode build
at a time; the type-checks of Scripts/ios/typecheck.py are lighter, but two of
them, or one beside a train's build, can still take the memory a build needs.
So both take this one lock first: a folder made with mkdir, which is atomic,
holding the owner's process ID, name, and start time.

A lock whose process has ended (a crash, a killed agent) is taken over, so a
dead owner never blocks the Mac. The lock lives in the main checkout's
gitignored build/orchestrator/, which every worktree shares.

One caller can wait first in line (`first=True`), which the build train does:
while it waits, no other caller takes the lock, even a free one, so the train
goes next once the job holding the lock ends. Until November 8, 2026 a train
that waited 20 minutes went on without the lock, beside the job holding it;
that day the user, finding the builds took a lot of CPU, asked for them "one
after the other", so the train now waits its turn and is given the first one.

Tickets keep the waiters in order. Until November 15, 2026 the waiters polled
every 10 seconds and whoever looked first after a release won, so on November
14 a type-check waited 78 minutes while later callers went ahead of it. Now a
caller that has to wait takes a ticket, a small JSON file in the line folder
(heavy-lock-line/, beside the lock), named so that the files sort in the order
they were taken, and takes the lock only when no live older ticket remains. A
ticket whose process has ended, or whose deadline has passed, counts for
nothing. The lock folder is still the one thing that decides who holds the
lock, so copies of this module that predate tickets (they take a free lock
without looking at the line) can never make two holders; tickets only order the
waiters of the new code. The first-in-line mark still goes ahead of every ticket.

`python3 -I -B heavy_lock.py status` prints the holder, the mark, and the line,
and changes nothing.

Used as a module (`held(owner, wait_seconds)`), it is imported by path, since
`python3 -I` leaves the script's own folder out of sys.path.
"""
import contextlib
import json
import os
import shutil
import sys
import time
from pathlib import Path

# Importing a sibling module must leave no __pycache__ folder in the repository (set before the import below).
sys.dont_write_bytecode = True
# repo_paths.py is beside this script; python3 -I leaves its folder out of sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

# The main checkout, where the lock lives whichever worktree calls.
ROOT = repo_paths.main_checkout()
LOCK = ROOT / "build" / "orchestrator" / "heavy-lock"
# The mark of the caller waiting first in line: its process ID, name, start
# time, and the time its wait ends, after which the mark counts for nothing.
FIRST = ROOT / "build" / "orchestrator" / "heavy-lock-first.json"
# How often a waiting caller looks again, in seconds.
POLL_SECONDS = 10
# The folder of waiting callers' tickets, beside the lock (so a test that points
# LOCK at a temporary folder moves the line with it).
LINE_NAME = "heavy-lock-line"
ORDINALS = ["next", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]


def _line_dir():
    """The folder holding the waiting callers' tickets."""
    return LOCK.parent / LINE_NAME


def _ticket_pid(ticket):
    """The process ID a ticket's file name carries ("<nanoseconds>-<pid>.json"), or None."""
    try:
        return int(ticket.stem.split("-")[1])
    except (IndexError, ValueError):
        return None


def _ticket_live(ticket):
    """The ticket's record when it still counts, else None.

    A ticket counts while its process runs and its deadline has not passed. The
    process ID comes from the file name, so a ticket seen between its creation
    and its contents being written still counts."""
    pid = _ticket_pid(ticket)
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except OSError:
        pass  # A process that exists but is not ours to signal still runs.
    try:
        record = json.loads(ticket.read_text())
        if time.time() > float(record["deadline"]):
            return None
    except (ValueError, KeyError, TypeError):
        record = {}  # Contents not written yet: counts, with no name to show.
    except OSError:
        return None  # Gone since it was listed (its owner took the lock).
    return {"name": "?", **record, "pid": pid}


def _drop(ticket):
    """Removes a ticket file; a ticket already gone is no trouble."""
    try:
        ticket.unlink()
    except OSError:
        pass


def line():
    """The live tickets as (path, record) pairs, oldest first. Tickets of ended
    processes and past deadlines are cleared away as they are found."""
    try:
        tickets = sorted(_line_dir().glob("*.json"))
    except OSError:
        return []
    live = []
    for ticket in tickets:
        record = _ticket_live(ticket)
        if record is None:
            _drop(ticket)
        else:
            live.append((ticket, record))
    return live


def _take_ticket(name, deadline):
    """Makes this caller's ticket, created atomically (O_CREAT | O_EXCL) and named
    so that file names sort in the order the tickets were taken; returns its path."""
    _line_dir().mkdir(parents=True, exist_ok=True)
    while True:
        ticket = _line_dir() / f"{time.time_ns():020d}-{os.getpid()}.json"
        try:
            handle = os.open(ticket, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            continue  # Another waiter of this process took the same instant: take the next.
        with os.fdopen(handle, "w") as out:
            out.write(json.dumps(_record(name, deadline=deadline)))
        return ticket


def place_in_line(ticket):
    """The tickets ahead of `ticket`: (how many, their names). A caller with no
    ticket yet (None) stands behind every live ticket."""
    ahead = [record for path, record in line() if ticket is None or path.name < ticket.name]
    return len(ahead), [record.get("name", "?") for record in ahead]


def _join(names):
    """"a", "a and b", "a, b and c"."""
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def describe_wait(record):
    """The waiting message for a record `on_wait` was given: its place and whom
    the caller stands behind ("third in line, behind typecheck-a and run-suite")."""
    behind = record.get("behind") or [record.get("name", "?")]
    place = record.get("place", 1)
    ordinal = ORDINALS[place - 1] if place <= len(ORDINALS) else f"number {place}"
    return f"{ordinal} in line, behind {_join(behind)}"


def _owner_alive(lock):
    """Whether the process named in `lock`'s owner file is still running."""
    try:
        owner = json.loads((lock / "owner.json").read_text())
        os.kill(int(owner["pid"]), 0)
        return True
    except (OSError, ValueError, KeyError, TypeError):
        # No owner file yet, an unreadable one, or a process that has ended:
        # the lock is stale. (A lock made a moment ago may not have its owner
        # file yet; the caller's next look, POLL_SECONDS later, sees it.)
        return False


def owner():
    """The current owner's record (pid, name, since), or None when the lock is free."""
    try:
        return json.loads((LOCK / "owner.json").read_text())
    except (OSError, ValueError):
        return None


def _record(name, **more):
    """A caller's record: this process's ID, `name`, the time now, and `more`."""
    return {"pid": os.getpid(), "name": name, "since": time.strftime("%Y-%m-%d %H:%M:%S"), **more}


def first_in_line():
    """The record of another caller waiting first in line, or None when there is none.

    A mark counts only while its process runs and its wait has not ended, so a
    train killed as it waited, or a later process given the same ID, holds no one back."""
    try:
        record = json.loads(FIRST.read_text())
        if int(record["pid"]) == os.getpid() or time.time() > float(record["until"]):
            return None
        os.kill(int(record["pid"]), 0)
        return record
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _leave_the_line():
    """Removes the first-in-line mark, if it is this process's own."""
    try:
        if int(json.loads(FIRST.read_text())["pid"]) == os.getpid():
            FIRST.unlink()
    except (OSError, ValueError, KeyError, TypeError):
        pass  # No mark, or another caller's: nothing of this process's to remove.


def say_wait(record):
    """An `on_wait` that tells the person watching (on stderr) the caller's place in line."""
    print(f"heavy-work lock: waiting, {describe_wait(record)} (held by {record.get('name', '?')} "
          f"since {record.get('since', '?')})", file=sys.stderr, flush=True)


def _waited_for(record, ticket):
    """`record` (whom the caller waits for) with its place in line added, for `on_wait`."""
    count, names = place_in_line(ticket)
    # The one holding the lock (or first in line) comes before the tickets.
    return {**record, "place": count + 1, "behind": [record.get("name", "?")] + names}


def acquire(name, wait_seconds, on_wait=None, first=False):
    """Takes the lock for `name`, waiting up to `wait_seconds`; True when taken.

    `on_wait`, when given, is called once, when the caller first has to wait,
    with the record of the one it waits for (the lock's owner, or the caller
    first in line) plus its `place` in line and the names it stands `behind`
    (see describe_wait), so it can say whom it waits for.

    A caller that has to wait takes a ticket and takes the lock only when no
    live older ticket remains, so waiters are served in the order they came.
    The ticket goes when the caller takes the lock, gives up, or is interrupted.

    With `first`, the caller takes no ticket: it marks itself first in line while
    it waits, so no other caller takes the lock before it, and removes the mark
    when its wait ends, with the lock or without it. A caller that looked just
    before the mark was made can still take the lock first; the mark only stops
    the rest."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + wait_seconds
    if first:
        FIRST.write_text(json.dumps(_record(name, until=deadline)))
    told = False
    stale_seen = False
    ticket = None
    try:
        while True:
            ahead = None if first else first_in_line()
            tickets_ahead = [] if first else place_in_line(ticket)[1]
            if ahead:
                # The lock may even be free, but it is the first caller's turn.
                stale_seen = False
                waiting_for = {**ahead, "name": f"{ahead.get('name', '?')}, first in line"}
            elif tickets_ahead:
                # Older waiters take the lock first, even if it is free now.
                stale_seen = False
                waiting_for = owner() or {"name": tickets_ahead[0]}
            else:
                try:
                    LOCK.mkdir()
                    (LOCK / "owner.json").write_text(json.dumps(_record(name)))
                    return True
                except FileExistsError:
                    if not _owner_alive(LOCK):
                        # Seen stale twice in a row (POLL_SECONDS apart), so it is not
                        # a lock whose owner is still writing its file: take it over.
                        if stale_seen:
                            shutil.rmtree(LOCK, ignore_errors=True)
                            stale_seen = False
                            continue
                        stale_seen = True
                        waiting_for = None
                    else:
                        stale_seen = False
                        waiting_for = owner()
            if waiting_for is not None and not first and (ticket is None or not ticket.exists()):
                # The caller has to wait: it takes its place at the back of the line.
                ticket = _take_ticket(name, deadline)
            if waiting_for is not None and on_wait and not told:
                on_wait(_waited_for(waiting_for, ticket))
                told = True
            if time.time() >= deadline:
                return False
            time.sleep(POLL_SECONDS)
    finally:
        if first:
            _leave_the_line()
        if ticket is not None:
            _drop(ticket)


def release():
    """Releases the lock, if this process holds it."""
    record = owner()
    if record and int(record.get("pid", -1)) == os.getpid():
        shutil.rmtree(LOCK, ignore_errors=True)


@contextlib.contextmanager
def held(name, wait_seconds, on_wait=None, first=False):
    """Holds the lock for the `with` block, waiting first in line with `first`
    (see acquire). Yields True when the lock was taken and False when the wait
    ran out, in which case the block runs anyway: the caller decides whether
    to go on without it."""
    taken = acquire(name, wait_seconds, on_wait, first)
    try:
        yield taken
    finally:
        if taken:
            release()


def _age(since):
    """How long ago a record's "since" stamp was, as text ("12 min"), or "?"."""
    try:
        seconds = max(0, int(time.time() - time.mktime(time.strptime(since, "%Y-%m-%d %H:%M:%S"))))
    except (ValueError, TypeError):
        return "?"
    return f"{seconds // 3600} h {seconds % 3600 // 60} min" if seconds >= 3600 else f"{seconds // 60} min"


def status_lines():
    """What `status` prints, as a list of lines: the holder and how long it has
    held the lock, the first-in-line mark, and the line in order. It changes
    nothing (it does not even clear tickets of ended processes)."""
    lines = []
    holder = owner()
    if holder and _owner_alive(LOCK):
        lines.append(f"holder: {holder.get('name', '?')} (process {holder.get('pid', '?')}), "
                     f"held for {_age(holder.get('since'))}")
    elif holder:
        lines.append(f"holder: none (the lock of {holder.get('name', '?')} is stale and will be taken over)")
    else:
        lines.append("holder: none")
    mark = first_in_line()
    lines.append(f"first in line: {mark.get('name', '?')} (process {mark.get('pid', '?')})" if mark
                 else "first in line: nobody")
    waiting = [(path, record) for path in sorted(_line_dir().glob("*.json"))
               if (record := _ticket_live(path)) is not None]
    if not waiting:
        lines.append("line: empty")
    for number, (_, record) in enumerate(waiting, 1):
        lines.append(f"line {number}: {record.get('name', '?')} (process {record['pid']}), "
                     f"waiting {_age(record.get('since'))}")
    return lines


def main(arguments):
    """The command line: `status` prints the lock's state; anything else prints usage."""
    if arguments != ["status"]:
        print("usage: heavy_lock.py status", file=sys.stderr)
        return 2
    print("\n".join(status_lines()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
