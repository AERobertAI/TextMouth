# Charter: team `pages` (October 21, 2026)

You are `pages-lead`, an Opus lead with Sonnet workers, on `team/pages`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"many other formats (Epub, pdf, docx / doc) at least are separated into pages and I think it would be reasonable if all of them supported them(including updating the parsers the text schema to have a special page tag or simular) so we can "go to page" or rewind and fastforward by page (I think page should just be a navigation unit like the others if you can get that working generally) and a optional page number/count on the reader screen / wear am I speech... Please make a feature section of TODOs for this if you think it would be good and lets make that the feature set implemented first today for the formats using pages."

## The design (settled; do not reopen it)
`PAGES-RESEARCH-2026-10-21.md` (merged on main, 3c7d43b1) holds it. Read sections 1, 2, 4, 5, 8, and 9 in full, and the rest as your items need.
- **The marker:** `<!-- page: LABEL -->`, with the placement, escaping, and reader behaviour of section 2.
- **Navigation:** section 4, with the keys, Go to Page…, the status row, Where Am I?, the settings, and their words.
- **Existing books:** section 5. The per-format page-reader version, and edited text kept.
- **The user's questions** (`humanQuestions/2026-10-21.md` in the main checkout) are built with their recommended answers:
  1. existing books are re-read at the next launch;
  2. braille "page" means the braille page;
  3. the page is shown on the screen and said in the brief Where Am I?, with both settings on;
  4. the keys are Option-Command-Right and Left Arrow, and Option-Command-G.

## Your items
The TODO's section "## Pages across formats (researched October 21)" holds them, in the main checkout's `TODO-2026-09-04.md`, which is gitignored. Read them with `grep -n -E "^- \[ \] \*\*(PG|B1[23])" TODO-2026-09-04.md`, then by line range.
- **Today:**
  - PG01;
  - PG02, PG03, and PG04, by one worker in that order;
  - PG05, PG06, PG07, and PG08;
  - B12, then PG09;
  - PG11, which fixes B13;
  - PG10's code part only: `BookTextEditWording.explanation` gains a line about page markers. The orchestrator runs the documentation pass after the merge.
- **Later, not today:**
  - PG12 waits for the `brailleemphasis` merge, and the orchestrator will tell you if it lands in time;
  - PG13, PG14, and PG15.

## How
- **The common rules.** Follow `Scripts/agents/briefs/2026-10-19/teams-common.md` (the board, the build wrapper, disk, tests, worker briefs, and the report's form), with today's line in place of its 58%: **start no new worker once the week is at 33% left**, since today's line is 30%. Use at most 8 Sonnet workers in all.
- **Order:** section 9 of the research.
  - **Phase 1:** PG01 alone, by one worker, or yourself if you judge it better, since every other item builds on it. Write its types' names into a short interface note, `Scripts/agents/briefs/2026-10-21/pages/interface.md`, before phase 2 starts, as team export did on October 19.
  - **Phase 2:** five workers in parallel, each on its own files, as the research's table says: reader (PG02 to PG04), epub (PG05), pdf (PG06), docx (PG07), and daisy (PG08).
  - **Phase 3:** one worker for B12 then PG09, and one for PG11. They may start as soon as their own dependencies merge.
- **Briefs** settle every type, sentence, label, hint, and test, which the October 19 lesson shows is what keeps workers from asking. Refresh each brief's line ranges before you launch it.
- **Shared files.** Shared fixtures (`samples.tsv`, the goldens) are each changed by the item that owns them. Merge conflicts in `samples.tsv` keep both sides, and a `project.pbxproj` conflict is settled with `xcodegen generate`.
- **Other agents** at work today:
  - `racefix` (branch `fix/reader-load-race`) edits the reader's load path. The orchestrator merges it into main first, and your reader worker rebases on main before it touches `ReaderViewModel.swift`.
  - `brailleemphasis` (branch `braille/emphasis`) owns the braille files, `BrailleBookReader.swift` above all. Leave braille alone.
- **Tests and runs:**
  - Every worker runs its item's classes from the TODO, plus `TextPipelineGoldenTests`, `ReadingTextCacheTests`, `PlaceRelocatorTests`, and `ExportDocumentWalkerTests`, in one `run-area.py` invocation.
  - Every worker runs `make lint-tests LINT_BASE=main`. The reader worker also runs `make lint-a11y LINT_BASE=main` and the `shortcuts`, `settings`, `headings`, and `reader-text` areas.
  - A hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first.
  - No test may trap, play a sound, or touch `~/.TextMouth` or `UserDefaults.standard`.
- **Your full run.** When everything is integrated, run the full suite once on `team/pages`. Name any load-sensitive failure (teams-common lists them), rerun its class alone, and report both results.
- **The review.** After your report, fresh Opus reviewers read the whole branch, and a fix round follows before the merge, as on October 19.

## The report
Teams-common's form, plus:
- the interface note's path;
- each PG item's outcome, with its commits;
- what the library's existing books will see at the next launch: which formats are re-read, and what is logged;
- every new sentence, label, hint, and value a listener hears;
- the README and TODO sentences;
- the follow-ups, including what PG12 needs from braille.
