# Resuming at 07:20, November 8, 2026: hourly trains, one heavy job after another

The user paused every agent and train at 04:45 because the builds took a lot of CPU. At 07:00 they said to go ahead again, and asked: "maybe lets try doing the builds every hour and putting themm one after the other to try using less resources. try telling the agents to like use there cycles wisely and to use the wait time to review there patches and fix any obvius issues so its less likely a hour cycle would be waisted, or to improve tests so each indiviusal build would give more information."

## What changed (main d4217696)

- **A train leaves every hour, on the hour.** The next ones are 08:00, 09:00, and so on.
- **Heavy jobs run strictly one after the other.** The train waits for the heavy-work lock first in line, so no other job takes the lock before it, and it never runs without the lock. Type-checks, `run_locked.py`, and simulator runs wait their turn behind it. A type-check now waits up to three hours for the lock.
- **The train tests the commit your request names, not your branch's newest.** If you commit a fix before the train leaves, request again: the newest request for a branch replaces the older one.
- `build-train.py status` says what a running train is doing: waiting for the lock and for whom, or which branches it builds.

## Making each train count

A missed train, or one spent on a mistake a careful reading would have caught, costs you an hour. The full text is in `docs/agents/working-with-agents.md` on main, under Making each train count. Read it in the main checkout: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/docs/agents/working-with-agents.md`.

1. **Review before you ask.** Read your whole diff against your base as an outside reviewer would. Look for a bug in plain sight, a missed edge case, a test that would still pass with the change undone, a stale comment, or a repeated block, and fix what you find. Then run the type-checks once for the whole batch, not after each edit, so no train is spent on a compile error.
2. **Ask once, for everything.** Send one request per batch of work, not one per commit. Name every class and area the change could break, not only those you edited.
3. **Make each test tell as much as it can.**
   - An assertion's message gives what was expected and what came instead: the values, the list of chapters, the words around a mismatch.
   - A test of a table checks every row and reports each mismatch.
   - When you are torn between two explanations, add a test for each, so one train settles both.
4. **Work while you wait.**
   - Wait with one background `wait-for-result.py --agent <you>`. Don't poll: each wake costs usage.
   - Meanwhile, review the patch again, write the next step's tests, check your documentation list, and draft your report.
5. **Read the whole result before changing anything.** Fix every failure in one round, review that round's diff, then request once.
6. **Batch your own heavy jobs.** A simulator run or a deliberate break on a scratch copy goes through `run_locked.py` and waits behind the train. Gather such runs into as few as you can.

## The rules, unchanged

- Never push, never `make install`, and never merge into main.
- Never read, stat, or copy the user's live library: `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- Delete nothing: overwrite files in a fixed folder of your own.
- Never wrap `make typecheck-*` in `run_locked.py`.
- No test may trap, hang, play sound, or record.
- In the simulator, never press Play.
