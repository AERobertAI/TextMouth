# Older follow-ups that are still real: imports and readers (November 9, 2026)

You are `sweep2`, a Sonnet worker, on branch `fix/followup-sweep-2`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

On November 7, a sweep of the TODO's older follow-up lists fixed what was small and real. It left a list, "Follow-ups, still real", in its merge entry ("Older recorded bugs a person could still hit"). The reader work of November 6 left two more. The items below are the ones a listener can meet on importing or opening a book, and they are your work.

## Read first

- The TODO entries "Older recorded bugs a person could still hit" and "The reader work's own follow-ups", in `TODO-2026-09-04.md`.
- In the main checkout's `build/orchestrator/followups1105/`: `sweep-report.md`, which says where each item was found.
- The pages of `docs/architecture/` for the code you touch.

## The work, in this order

Each item gets a test that fails without its fix. If time runs short, stop after a finished item and list the rest in your report.

1. **Text without a byte-order mark.** BOM-less UTF-16 and UTF-32 aren't detected, nor is an HTML file that declares ISO-2022-JP. Detect them in the one decoder every text import uses (`TextFileDecoder`), without misreading ordinary 8-bit text as UTF-16. Prove that last part on the text samples in `TestData`.
2. **Moving a book stored outside the data directory** gives a misleading message. Say what really happened and what to do.
3. **A book folder that is itself a symbolic link** scans as an error. Read it as the folder it points to, or refuse it with a clear sentence, whichever the scan's other rules for links make safe. Report which.
4. **A DOCX whose `dc:title` is empty**, or only spaces, uses it as the title. Fall back as a DOCX without a title does.
5. **ZIP damage in a DOCX or a DAISY book** shows ZIPFoundation's raw error. Say in plain words that the file is damaged, as the other readers' refusals do, and log the raw error.
6. **A refused SMIL file** silences the "text beyond audio" notice in a DAISY book. Keep the notice.
7. **Two architecture pages describe the old XML guard,** in their passages on `XMLInputGuard`: `docs/architecture/shared-helpers.md` and `docs/architecture/state/imports.md`. The line numbers the TODO gives have moved. Correct both from the code. This branch may edit those two pages.

## Checks

- One train for the batch, with the areas of `Scripts/test/areas.conf` that hold the import, reader, DAISY, and library classes, and every class your change could touch.
- If a change alters what a reader makes of an existing book, raise that reader's version, as `common.md` says. If the format has no version, say so: then only new imports change.
