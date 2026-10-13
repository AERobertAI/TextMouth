# Task brief: docs13, the documentation pass for the later October 12 and 13 merges

Slug `docs13`; branch `docs/october-13`, made from local main with `git checkout -b docs/october-13 main`. You run on Sonnet at effort high, and the orchestrator reviews your diff itself. Read `common.md` beside this file for the rules everyone follows. This task builds nothing, so skip common.md's build steps. Two of its rules do not apply here: the rule against editing `*.md` files, since editing README.md and ARCHITECTURE.md is this task; and its list of documents not to read, since this task reads those two files, `AGENT-NOTES-2026-10-04.md`, and the TODO's entries for these merges. Read each by line range, never whole.

## What to do
Bring `README.md` and `ARCHITECTURE.md` up to date with the six merges since the last documentation pass, `docs/october-12` (merged 72e863d2). Make one commit per merge documented, in this order, each touching both files as needed:

1. **The second polish team's eight fixes:** `team/polish2`.
2. **The message board's follow-ups after teams:** `team/board2`. This is tooling: ARCHITECTURE only if it already describes the board; README's "Working on TextMouth with coding agents" section may gain a sentence.
3. **T06's branch D,** places moved when TextMouth rebuilds a book's text: `team/t6d`.
4. **The third polish team's ten tasks:** `team/polish3`.
5. **The fourth polish team:** `team/polish4`, mostly renames, so ARCHITECTURE only.
6. **T06's branch E,** places moved at every load and by Edit Text: `team/t6e`. With it, T06 is complete, so its sentences and branch D's should read as one account of how saved places follow their text.

## Where the words are
Each merge's team wrote the sentences its change needs. They are in `AGENT-NOTES-2026-10-04.md`, under these headings:
- "From the second polish team";
- "From the board follow-ups team";
- "From the t6d team";
- "From the third polish team";
- "From the fourth polish team";
- "From the t6e team".

Each merge's entry in `TODO-2026-09-04.md` (search for its branch name in backquotes) says what it did, and `git show <merge> --stat` shows its files.

## How
- **Find the right section** for each sentence: README.md is for the listener; ARCHITECTURE.md is for whoever reads the code. Read each file's headings first (`grep -n "^#" README.md ARCHITECTURE.md`), then only the sections you change, by line range.
- **Check each sentence against main's code** before you paste it, with one `grep` for the names it uses. Where the code says otherwise, write what the code does and say so in your report.
- **Keep each file true and DRY.** Replace a sentence that a merge made untrue, rather than adding a contradicting one. Do not repeat a fact the file already states.
- **Match the files' own style.** Plain words for a VoiceOver and braille user, lists rather than tables, and no arrows or symbols standing for words. Keep the wording of announcements exact, in quotation marks, as the code has them.
- **Commit each merge's changes** with a message whose subject says which merge it documents, ending `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Stage with `git add -f`, since `*.md` is ignored except README.md.

## Report
At most 25 lines:
- the branch, and each commit's hash and subject;
- for each merge, where its sentences went (file and heading);
- every sentence you changed from the agent's wording, and why;
- anything you could not place, or found untrue against the code.
