# Triage of the TODO's open items (November 13, 2026)

You are `triage1113`, a Sonnet reader. You change no code and make no branch. First read `common.md` beside this brief and follow its rules; you make no commits, and you edit only your report.

## The user's words

On November 13, 2026: "Ok I want you to keep working through the todos for Text Mouth."

## What to read

- `TODO-2026-09-04.md` in the main checkout (5,969 lines):
  - the paragraph that begins `**Open follow-ups noted on October 3 afternoon and evening**` (line 4418 to about 4584, about 100 KB): the open follow-ups of every merge since October 3, newest last;
  - the open `- [ ]` entries (`grep -n "^- \[ \]"`), most of them new formats (FMT…) and pages (PG…);
  - the follow-ups named in the merge entries of November 5 to 11.
- `AGENT-NOTES-2026-10-04.md` only where an item points to it.
- The code, enough to tell whether each item is still open: many were fixed by later merges without being struck.

## What is out of scope

Today's agents own these; list any item that falls in them under "Owned today", with its line, and don't plan it:
- the sleep timer and its hand-over (`wintimer`);
- title sorting, the Library list's order, and letter navigation (`articles`);
- any search: Search in Book and searching the library (`libsearch`);
- the reading list (`rlfinished`);
- the app's size, memory, and speed (`optaudit`);
- the iPhone's unit and interface tests on GitHub (`iosunitfix2`).

Items that need the user (a hand check, a decision, an install, a real device or drive) go under "Needs the user", each with the question in one sentence and a recommended answer.

## Your report

Write it to `build/orchestrator/nov13/triage-report.md` in the main checkout:

1. **Still open and doable today without the user**: up to 40 items, best first (what the user notices most, then risk of data loss, then crashes, then the rest). For each:
   - a short title, and the TODO line it comes from;
   - the evidence it is still open: the file and line, and what the code does;
   - the fix in one to three sentences, and the test that would prove it;
   - its size: S (one commit) or M (two or three);
   - the files it touches.
2. **Batches**: the items above grouped into batches of three to six items each, so that no two batches touch the same files and each batch suits one Sonnet worker for a few hours. Name each batch, and say which test classes its train request should name.
3. **New formats worth doing now**: of the open FMT and PG entries, the three to five with the most value for a blind listener's library (the user's own wishes first), each with its size, and whether its research is complete enough for a worker to start.
4. **Already done**: items the code shows are done, with the evidence, so the orchestrator can strike them.
5. **Needs the user** and **Owned today**, as above.

Your final message is a summary of at most 40 lines; save it also as `build/orchestrator/nov13/triage1113-report.md`.
