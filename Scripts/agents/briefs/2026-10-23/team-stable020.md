# Charter: team `stable020` (October 23, 2026)

You are `stable020-lead`, an Opus lead with Sonnet workers, on `team/stable020`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"I want to install the new version with it as stable as you can make it so also plan any todos requiring breaking changes for my official update to 0.2.0."

## Your items
They are in the TODO's section "## Before the official 0.2.0 install (planned October 23)". The TODO is gitignored, so read it in the main checkout at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`: `grep -n -E "^- \[ \] \*\*(ST|V0)" TODO-2026-09-04.md`, then by line range. The detail and evidence for each are in `PLAN-0.2.0-2026-10-23.md` on main, in §3.2 and the V items. Read the questions in `humanQuestions/2026-10-23.md`, also in the main checkout.

Build them in this order, and keep each a small commit with its test:
1. **The two that touch the first launch:**
   - ST02, an EPUB page-break element loses its text;
   - ST01, rebase the path during the batch, and mind open readers.
2. **ST05:** Edit Text, a marker at a line's start.
3. **ST03:** Resume after a quick Pause.
4. **ST08:** Play during a move.
5. **ST09:** EPUB case-insensitive lookup.
6. **ST04:** Replace Existing loses state. Carry the old book's state over under its ID if you can, or at least say in the dialog what is lost, with words pinned in tests.
7. **V02:** pin the on-disk contract.
8. **V03:** open a library that a later version wrote. This is question 2's recommended answer, being built.
9. **If the budget allows:** ST06 (precise MP3 timing), ST07 (time limits on `AsyncBridge.waitForResult`), and ST10 (textutil field instructions).

Leave out V01 (the documentation pass does it), V04, V05, V06, V07, and the rehearsal, which waits for the user's answer to question 3.

## How
- **The common rules.** Follow `Scripts/agents/briefs/2026-10-19/teams-common.md`: the board, the build wrapper, tests, worker briefs, and the report's form.
- **Others at work.** Team `transcripts` (lead `transcripts-lead`, branch `team/transcripts`) is working tonight on transcription, a transcript search, export escaping, Retranscribe Audio…, and a review of transcription.
  - Touch none of its files. Claim yours on the board, and read its claims (`bbs.py claims`) before you plan.
  - Where an item of yours needs one of its files, such as ST04's transcript, or an Edit Text check in `BookTextEditing.swift`, post on the board and agree an order with `transcripts-lead`.
  - The orchestrator merges team transcripts first.
- **Budget.** Tonight's line is 5% of the week left; it is about 23% now, shared with team transcripts. Start no new worker below 9% left, and use at most 6 Sonnet workers.
- **Disk.** It has about 11 GB free, shared with team transcripts. At most two of your builds at once, and check for 4 GB before each. Workers delete build folders as soon as their last run ends.
- **Briefs** settle every type, sentence, label, hint, and test, and list the exact-output tests a worker may change.
- **Tests:**
  - none may trap, play a sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`;
  - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first.
- **Your full run.** When everything is integrated, run the full suite once. Name any load-sensitive failure (teams-common lists them), rerun its class alone, and report both.
- **Never** push or merge into main.

## The report
Teams-common's form, plus:
- each item's outcome, with its commits;
- every new sentence a listener hears;
- what the first launch now does differently;
- the follow-ups.
