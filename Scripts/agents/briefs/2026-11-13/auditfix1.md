# The audit's small runtime fixes (November 13, 2026, evening)

You are `auditfix1`, a Sonnet worker. First read `common.md` beside this brief and follow it: its rules bind you (the live library, `rm` with literal paths only, no search from `/` or `~`, builds only through the heavy-work lock, trains on GitHub, no push except through the train tools, no merge into main).

## The user's words

On November 13, 2026, the user asked for a Fable audit of TextMouth's size, memory, and CPU, and to keep working the TODOs. That evening: "please have the agents resume."

## Your branch

`git switch -c perf/audit-small main` (main is a56f8a20 or later: version 0.4.7, with the per-window sleep timer merged).

## Your items

They are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/optaudit/audit-report.md`, Part C, each with where, mechanism, gain, risk, and tests:

1. **C16. Timers: tolerance, and one hop for the sleep countdown.** Both halves: the sleep timer's change has merged, so the second half is yours too. The countdown's own interval stays exact.
2. **C17. Small per-second work in the reader.** One commit for each of its bullets.
3. **C4. Rendered speech: publish the position in the tick, and only when it moved.**
4. **C6. Refresh on the leading edge.** The End of heading tests of 0.4.6 and `IntegrationSleepTimerTests` must pass unchanged.
5. **C7. The Library's summary bar: add up once.** Leading articles has merged, so `LibrarySubviews` is free.

The audit was read from an older main. **Check each item in the code before you change it**: line numbers have moved, and the sleep timer is now one per window (`SleepTimerRegistry`, `WindowSleepTimerHolder`). If an item is already done or its evidence is wrong, skip it and say why. If its fix needs more than the item says, take the smallest right fix and say why.

**Leave C3 alone** (the reader window's publishing). It is the larger change and has its own brief later. Remember while you work that the reader's sleep countdown line moves today only because the reader publishes often: nothing you change may make the reader publish less often. C6 makes refreshes come earlier, never later.

## How to work

- One commit per item, or per bullet of C17, each with its test. A test must fail without its fix: prove that with a scratch copy through `run_locked.py`, by a GitHub run you send by hand, or by reading where only the hosted app shows it, never on a shared train. Say how in the report.
- Then `make typecheck-tests REF=<commit>` and one train request naming every class the items list plus any you add (`--areas` for playback, speech, reader, library).
- While the train runs, review your whole diff (`git diff main...HEAD`) and fix what you find; ask again if you committed.
- Before your report, follow `common.md`: rebase onto local main, type-check, and one last broad train.
- Stop at your report. If the weekly usage tool says under 12% left (`python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`, "wk:"), finish the item in hand, commit it, and report what is done.

## Your report

Follow `common.md`'s report, saved as `build/orchestrator/nov13/auditfix1-report.md`. For each item: done, skipped (why), or changed in scope (why); its commit; its test; whether a break fails it; the trains with their counts.
