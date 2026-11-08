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

Used as a module (`held(owner, wait_seconds)`), it is imported by path, since
`python3 -I` leaves the script's own folder out of sys.path.
"""
import contextlib
import json
import os
import shutil
import time
from pathlib import Path

# The main checkout, where the lock lives whichever worktree calls.
ROOT = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth")
LOCK = ROOT / "build" / "orchestrator" / "heavy-lock"
# The mark of the caller waiting first in line: its process ID, name, start
# time, and the time its wait ends, after which the mark counts for nothing.
FIRST = ROOT / "build" / "orchestrator" / "heavy-lock-first.json"
# How often a waiting caller looks again, in seconds.
POLL_SECONDS = 10


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


def acquire(name, wait_seconds, on_wait=None, first=False):
    """Takes the lock for `name`, waiting up to `wait_seconds`; True when taken.

    `on_wait`, when given, is called once, when the caller first has to wait,
    with the record of the one it waits for (the lock's owner, or the caller
    first in line), so it can say whom it waits for.

    With `first`, the caller marks itself first in line while it waits, so no
    other caller takes the lock before it, and removes the mark when its wait
    ends, with the lock or without it. A caller that looked just before the
    mark was made can still take the lock first; the mark only stops the rest."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + wait_seconds
    if first:
        FIRST.write_text(json.dumps(_record(name, until=deadline)))
    told = False
    stale_seen = False
    try:
        while True:
            ahead = None if first else first_in_line()
            if ahead:
                # The lock may even be free, but it is the first caller's turn.
                stale_seen = False
                if on_wait and not told:
                    on_wait({**ahead, "name": f"{ahead.get('name', '?')}, first in line"})
                    told = True
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
                    else:
                        stale_seen = False
                        if on_wait and not told:
                            on_wait(owner())
                            told = True
            if time.time() >= deadline:
                return False
            time.sleep(POLL_SECONDS)
    finally:
        if first:
            _leave_the_line()


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
