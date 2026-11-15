"""Tests of heavy_lock.py: one heavy job at a time, with the build train first in line.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test points the module at a temporary folder before it calls anything, so
the Mac's real lock in build/orchestrator/ is never read, taken, or removed.
"""
import contextlib
import io
import json
import os
import threading
import time
import unittest

# The shared base class is beside this file; unittest discover puts the folder on sys.path.
from heavy_lock_case import HeavyLockTestCase
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)


class AcquireTests(HeavyLockTestCase):
    """The lock as every caller takes it."""

    def test_a_free_lock_is_taken_at_once_and_released(self):
        self.assertTrue(heavy_lock.acquire("a type-check", 0))
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")
        self.assertEqual(heavy_lock.owner()["pid"], os.getpid())
        heavy_lock.release()
        self.assertFalse(heavy_lock.LOCK.exists(), "release() should remove the lock")

    def test_a_held_lock_is_waited_for_and_taken_when_its_job_ends(self):
        self.hold_lock(self.live_pid())
        told = []
        self.later(0.15, self.free_lock)
        self.assertTrue(heavy_lock.acquire("a type-check", 5, told.append))
        self.assertEqual([record["name"] for record in told], ["holder"],
                         "the waiter should be told once whom it waits for")
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")

    def test_a_held_lock_is_not_taken_when_the_wait_runs_out(self):
        self.hold_lock(self.live_pid())
        self.assertFalse(heavy_lock.acquire("a type-check", 0.1))
        self.assertEqual(heavy_lock.owner()["name"], "holder", "the holder's lock should be left alone")

    def test_a_lock_whose_owner_has_ended_is_taken_over(self):
        self.hold_lock(self.ended_pid())
        self.assertTrue(heavy_lock.acquire("a type-check", 1))
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")


class FirstInLineTests(HeavyLockTestCase):
    """The build train's turn, which comes before every other caller's."""

    def test_a_caller_first_in_line_holds_off_others_even_from_a_free_lock(self):
        self.mark_first(self.live_pid(), time.time() + 60)
        told = []
        self.assertFalse(heavy_lock.acquire("a type-check", 0.15, told.append))
        self.assertFalse(heavy_lock.LOCK.exists(), "no one but the train should take the lock while it waits")
        self.assertEqual([record["name"] for record in told], ["build-train, first in line"])

    def test_a_mark_whose_process_has_ended_counts_for_nothing(self):
        self.mark_first(self.ended_pid(), time.time() + 60)
        self.assertTrue(heavy_lock.acquire("a type-check", 0))

    def test_a_mark_whose_wait_has_ended_counts_for_nothing(self):
        # A live process that took the ID of a train killed as it waited, say.
        self.mark_first(self.live_pid(), time.time() - 1)
        self.assertTrue(heavy_lock.acquire("a type-check", 0))

    def test_the_first_caller_marks_its_wait_and_removes_the_mark_once_it_has_the_lock(self):
        self.hold_lock(self.live_pid())
        seen = {}

        def look_then_free():
            seen["mark"] = json.loads(heavy_lock.FIRST.read_text())
            self.free_lock()

        self.later(0.15, look_then_free)
        self.assertTrue(heavy_lock.acquire("build-train", 5, first=True))
        self.assertEqual(seen["mark"]["name"], "build-train")
        self.assertEqual(seen["mark"]["pid"], os.getpid())
        self.assertGreater(seen["mark"]["until"], time.time(), "the mark should say when the wait ends")
        self.assertFalse(heavy_lock.FIRST.exists(), "the mark should go once the lock is taken")
        self.assertEqual(heavy_lock.owner()["name"], "build-train")

    def test_the_first_caller_removes_its_mark_when_it_gives_up(self):
        self.hold_lock(self.live_pid())
        self.assertFalse(heavy_lock.acquire("build-train", 0.1, first=True))
        self.assertFalse(heavy_lock.FIRST.exists(), "a train that gave up should hold no one back")

    def test_another_callers_mark_is_left_in_place(self):
        self.mark_first(self.live_pid(), time.time() + 60)
        heavy_lock._leave_the_line()
        self.assertTrue(heavy_lock.FIRST.exists(), "only the mark's own process may remove it")

    def test_held_passes_first_on(self):
        self.hold_lock(self.live_pid())
        with heavy_lock.held("build-train", 0.1, first=True) as taken:
            self.assertFalse(taken)
        self.assertFalse(heavy_lock.FIRST.exists())
        self.assertEqual(heavy_lock.owner()["name"], "holder", "a lock not taken should not be released")


class LineTests(HeavyLockTestCase):
    """Tickets: waiters are served in the order they came."""

    def waiter(self, name, order):
        """A thread that waits for the lock as `name`, notes its turn, and releases."""
        def work():
            if heavy_lock.acquire(name, 10):
                order.append(name)
                heavy_lock.release()
        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        return thread

    def test_three_waiters_are_served_in_the_order_they_came(self):
        self.hold_lock(self.live_pid())
        order, threads = [], []
        for name in ("first", "second", "third"):
            threads.append(self.waiter(name, order))
            # Let each one take its ticket before the next starts.
            deadline = time.time() + 5
            while len(self.tickets()) < len(threads) and time.time() < deadline:
                time.sleep(0.005)
        self.assertEqual(len(self.tickets()), 3)
        self.free_lock()
        for thread in threads:
            thread.join(10)
        self.assertEqual(order, ["first", "second", "third"])
        self.assertEqual(self.tickets(), [], "every waiter should have removed its ticket")

    def test_a_dead_waiters_ticket_is_skipped(self):
        self.write_ticket(self.ended_pid(), "gone")
        self.assertTrue(heavy_lock.acquire("a type-check", 1))
        self.assertEqual(self.tickets(), [])

    def test_an_expired_ticket_is_skipped(self):
        # A live process, but its wait ended: its ticket holds no one back.
        self.write_ticket(self.live_pid(), "late", deadline=time.time() - 1)
        self.assertTrue(heavy_lock.acquire("a type-check", 1))

    def test_a_live_older_ticket_is_waited_for_even_when_the_lock_is_free(self):
        self.write_ticket(self.live_pid(), "older")
        self.assertFalse(heavy_lock.acquire("a type-check", 0.15))
        self.assertFalse(heavy_lock.LOCK.exists(), "the older waiter's turn: the lock stays free")
        self.assertEqual(len(self.tickets()), 1, "the timed-out caller should leave only the older ticket")

    def test_the_mark_first_in_line_goes_ahead_of_older_tickets(self):
        self.write_ticket(self.live_pid(), "older")
        self.assertTrue(heavy_lock.acquire("build-train", 1, first=True))
        self.assertEqual(heavy_lock.owner()["name"], "build-train")
        self.assertEqual(len(self.tickets()), 1, "the train takes no ticket and leaves the others' alone")

    def test_an_old_style_caller_taking_a_free_lock_leaves_the_line_as_it_was(self):
        older = self.write_ticket(self.live_pid(), "older")
        before = older.read_text()
        # What a copy of the module from before tickets does: take the free lock.
        self.hold_lock(self.live_pid(), "old copy")
        self.assertEqual(self.tickets(), [older])
        self.assertEqual(older.read_text(), before)
        # The lock folder alone decides: the new code's waiters wait for it.
        # The older waiter leaves the line (a rename, out of the line's folder), so
        # the new caller is next in line while the old copy still holds the lock.
        self.later(0.1, lambda: older.rename(self.folder / "left-the-line.json"))
        self.assertFalse(heavy_lock.acquire("a type-check", 0.4))
        self.assertEqual(heavy_lock.owner()["name"], "old copy", "there must never be two holders")

    def test_a_waiter_that_times_out_leaves_no_ticket(self):
        self.hold_lock(self.live_pid())
        self.assertFalse(heavy_lock.acquire("a type-check", 0.1))
        self.assertEqual(self.tickets(), [])

    def test_a_waiter_that_is_interrupted_leaves_no_ticket(self):
        self.hold_lock(self.live_pid())

        def interrupt(record):
            # on_wait runs once the ticket is taken; Ctrl-C could land any time after.
            self.assertEqual(len(self.tickets()), 1)
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            heavy_lock.acquire("a type-check", 5, interrupt)
        self.assertEqual(self.tickets(), [])

    def test_a_waiter_that_takes_the_lock_removes_its_ticket(self):
        self.hold_lock(self.live_pid())
        self.later(0.1, self.free_lock)
        self.assertTrue(heavy_lock.acquire("a type-check", 5))
        self.assertEqual(self.tickets(), [])

    def test_the_waiting_message_names_the_place_in_line(self):
        self.hold_lock(self.live_pid(), "run-suite")
        self.write_ticket(self.live_pid(), "typecheck-a", stamp=1)
        told = []
        self.assertFalse(heavy_lock.acquire("typecheck-b", 0.1, told.append))
        self.assertEqual(heavy_lock.describe_wait(told[0]), "second in line, behind run-suite and typecheck-a")

    def test_the_first_caller_in_line_is_told_it_is_next(self):
        self.hold_lock(self.live_pid(), "run-suite")
        told = []
        self.assertFalse(heavy_lock.acquire("typecheck-a", 0.1, told.append))
        self.assertEqual(heavy_lock.describe_wait(told[0]), "next in line, behind run-suite")

    def test_the_third_place_is_spoken_as_third(self):
        self.hold_lock(self.live_pid(), "holder")
        self.write_ticket(self.live_pid(), "typecheck-a", stamp=1)
        self.write_ticket(self.live_pid(), "run-suite", stamp=2)
        told = []
        self.assertFalse(heavy_lock.acquire("typecheck-b", 0.1, told.append))
        self.assertEqual(heavy_lock.describe_wait(told[0]),
                         "third in line, behind holder, typecheck-a and run-suite")


    def test_say_wait_prints_the_place_on_stderr(self):
        self.hold_lock(self.live_pid(), "run-suite")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            self.assertFalse(heavy_lock.acquire("typecheck-a", 0.1, heavy_lock.say_wait))
        self.assertIn("next in line, behind run-suite", errors.getvalue())


class StatusTests(HeavyLockTestCase):
    """The status command prints the lock's state and changes nothing."""

    def test_status_with_no_holder_and_no_line(self):
        self.assertEqual(heavy_lock.status_lines(),
                         ["holder: none", "first in line: nobody", "line: empty"])

    def test_status_names_the_holder_and_how_long_it_has_held_the_lock(self):
        pid = self.live_pid()
        heavy_lock.LOCK.mkdir()
        since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 5 * 60))
        (heavy_lock.LOCK / "owner.json").write_text(json.dumps({"pid": pid, "name": "run-suite", "since": since}))
        self.assertEqual(heavy_lock.status_lines()[0], f"holder: run-suite (process {pid}), held for 5 min")

    def test_status_shows_the_mark_and_the_line_in_order_and_changes_nothing(self):
        self.hold_lock(self.live_pid())
        pid = self.live_pid()
        self.mark_first(pid, time.time() + 60)
        self.write_ticket(self.live_pid(), "second", stamp=2)
        self.write_ticket(self.live_pid(), "first", stamp=1)
        dead = self.write_ticket(self.ended_pid(), "gone", stamp=3)
        lines = heavy_lock.status_lines()
        self.assertEqual(lines[1], f"first in line: build-train (process {pid})")
        self.assertTrue(lines[2].startswith("line 1: first "), lines)
        self.assertTrue(lines[3].startswith("line 2: second "), lines)
        self.assertEqual(len(lines), 4, "a dead waiter should not be listed")
        self.assertTrue(dead.exists(), "status must change nothing, not even a dead ticket")

    def test_main_prints_the_status_and_refuses_other_commands(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(heavy_lock.main(["status"]), 0)
        self.assertIn("holder: none", output.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(heavy_lock.main(["release"]), 2)


if __name__ == "__main__":
    unittest.main()
