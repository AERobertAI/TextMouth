# Task brief: docs12, the documentation pass for the October 10 and 12 merges

Slug `docs12`; branch `docs/october-12`, made from local main with `git checkout -b docs/october-12 main`. You run on Sonnet at effort high, and the orchestrator reviews your diff itself. Read `common.md` beside this file for the rules everyone follows. This task builds nothing, so skip common.md's build steps. Two of its rules do not apply here: the rule against editing `*.md` files, since editing README.md and ARCHITECTURE.md is this task; and its list of documents not to read, since this task reads those two files, `AGENT-NOTES-2026-10-04.md`, and the TODO's entries for these merges. Read each by line range, never whole.

## What to do
Bring `README.md` and `ARCHITECTURE.md` up to date with the seven merges since the last documentation pass. That pass was `docs/october-10-evening`, merged a781aad6. Make one commit per merge documented, in this order, each touching both files as needed:

1. **T06's branch B,** every saved place keeps its words: `feature/text-anchors-capture`.
2. **REV14's reader findings:** `fix/rev14-reader-findings`.
3. **REV14's feed findings:** `fix/rev14-feed-findings`.
4. **T06's branch C,** the diff relocator: `feature/place-diff`.
5. **REV15's fixes to the place relocator:** `fix/rev15-place-relocator`. Its skipped-heading sentences replace branch C's sentence about skipped headings.
6. **The message board's teams:** `team/board`. This is tooling: ARCHITECTURE only if it already describes the board, and README's "Working on TextMouth with coding agents" section may gain a sentence.
7. **The polish team's eight fixes:** `team/polish`.

## Where the words are
Each merge's agent wrote the sentences its change needs. They are in `AGENT-NOTES-2026-10-04.md`, under these headings:
- "From the anchorcapture agent";
- "From the endfixes agent";
- "From the feedfixes14 agent";
- "From the placediff agent";
- "From the rev15fixes agent";
- "From the board team";
- "From the polish team".

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
