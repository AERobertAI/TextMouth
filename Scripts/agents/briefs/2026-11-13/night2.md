# Two pieces of work held for the user's word (November 14, 2026, before the reset)

You are one of two Sonnet workers, `brfguess` or `bookbox`; your launch message says which. First read `common.md` beside this brief and follow it. Its rules bind you:
- the live library;
- `rm` with literal paths only;
- no search from `/` or `~`;
- builds only through the heavy-work lock;
- trains on GitHub;
- no push except through the train tools;
- no merge into main.

**Delete nothing tonight.** Main is 0.4.9 (7b26cf12 or later).

## If the usage limit stops you

The weekly limit may stop you; the orchestrator resumes you after the reset at 07:00 EST. **Commit after every step**, and keep `PROGRESS-<your name>.md` at your worktree's root, staged with `git add -f`.

## `brfguess`, branch `feature/braille-code-guess`

The user asked: "Is there already code to try guessing the braille code from brfs like how there is a text encoding guesser?" There is none. `BrailleCodeDetector` only puts a sentence in Book Information. The orchestrator offered to build a guess at import; **this branch is built so the user can decide, and is not merged until they say yes.**

Read first:
- `BRAILLE-CODES-RESEARCH-2026-10-25.md` (main checkout): never guess among seven-bit file codes. That is about file characters; this branch guesses the table, UEB or English Braille, American Edition.
- `TextMouth/Parsers/BrailleCodeDetector.swift`.
- How the text encoding guess records itself (`textEncodingSource`, `TextEncodingRecord`).

Build:
1. At import of a BRF or BRL (not PEF) headed for a contracted UEB table, run the detector with a **stricter** rule than the suggestion uses. When it is clearly English Braille, American Edition, read the book with the bundled contracted EBAE table (`en_US.tbl`) instead.
   - Count only the signs UEB dropped (joined to/by, and `,N`/`,Y` inside a word, per distinct word). BANA's UEB FAQ: UEB eliminated ally, ation, ble, by, com, dd, into, o'clock, to.
   - Pick thresholds that the EBAE samples pass and that a large UEB sample, built with liblouis forward on the repo's `en-ueb-g2.ctb`, never reaches.
2. Record that the table was guessed, as the text encoding does: an optional source field, absent for every existing book. Book Information then names the code with "(guessed)" or similar plain wording. Choosing a code there replaces the guess for good.
3. When unsure, keep the user's Braille setting and the existing suggestion.
4. A setting to turn the guess off, in the Braille tab, on by default. Keep the wording plain for VoiceOver.
5. No reader version raise for books already in the library: they are not guessed again. Say so in the report.

Write tests with invented and liblouis-forward braille, never a real book's text, including an older-row decoding test for the new field.

## `bookbox`, a measurement only, no branch to merge

This is audit item C13 in `build/orchestrator/optaudit/audit-report.md`, Part C: `Book` as one reference, copied on write. The audit says to build it in a scratch copy first and measure before anyone commits.

In a scratch copy of main, under `build/orchestrator/bookbox/` (keep it under 3 GB):
1. Do the refactor far enough to build Release: keep `struct Book` and its API, with its stored fields in one final class copied on write.
2. Measure the Release app's size against main's, with `make check CHECK_ARGS=--without-tests` through `run_locked.py`.
3. Measure the time to copy 1,500 books, against main's.
4. Note what broke and what it would take to finish (`OnDiskContractTests` byte-for-byte JSON, and the `UncheckedConcurrencyPolicyTests` entry).

Commit nothing to any shared branch. Your report is the measurement, so the user can decide.

## Report

At most 35 lines, as `common.md` says. Your worktree may refuse writes outside it, so your final message is the record.
