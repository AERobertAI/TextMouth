# Brief: pages across formats, research and plan (October 21, 2026)

You are `pages-research`, an Opus agent, on the branch `research/pages`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display. You research and plan; you write no app code.

## The request, in the user's words
"For pages It might be a good idea but it would also open up a big can of worms... sense many other formats (Epub, pdf, docx / doc) at least are separated into pages and I think it would be reasonable if all of them supported them(including updating the parsers the text schema to have a special page tag or simular) so we can "go to page" or rewind and fastforward by page (I think page should just be a navigation unit like the others if you can get that working generally) and a optional page number/count on the reader screen / wear am I speech... Please make a feature section of TODOs for this if you think it would be good and lets make that the feature set implemented first today for the formats using pages."

The orchestrator will turn your plan into a TODO section and launch an implementation team today, so make it concrete enough for that: settled decisions, exact names, and file ownership.

## Deliverables
1. `PAGES-RESEARCH-2026-10-21.md` in the repository root, in the style of the other research documents (for example `FORMATS-RESEARCH-2026-10-17.md` and `TEXT-ANCHORS-RESEARCH-2026-10-10.md`, which are gitignored and in the main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`). Commit it with `git add -f` on `research/pages`.
2. Inside it, a section "TODO section draft": items PG01, PG02, and so on, each in the form of the FMT items in `TODO-2026-09-04.md` (main checkout; see `grep -n "^- \[ \] \*\*FMT43 " TODO-2026-09-04.md` for the form): a title, difficulty, impact, what and why, files, risks, samples, and dependencies. Order them as they should be built.
3. Inside it, a section "Team plan": the order of work, which items can run in parallel, each worker task's files (so no two workers edit one file at once), and which existing test classes each task must run.
4. Questions for the user, each with a recommended answer, only where a choice is truly theirs.

Time-box: about 45 minutes. Read by line range, put several patterns in one grep, and keep it lean.

## What to find out (answer each in the document, with file and line references)
1. **The text schema today.**
   - How content.md marks chapters (`<!-- chapter: Title -->`, `TextMouth/Services/MarkdownCacheService.swift`) and navigation annotations.
   - How the reader builds its content model from content.md: chapters, headings, paragraphs, and sentences. How positions are stored (character offsets, text anchors), for places, bookmarks, skipped headings, and the sleep timer's End of heading.
   - How Edit Text (`docs/user/editing-book-text.md`) and T06's relocator (`TEXT-ANCHORS-RESEARCH-2026-10-10.md`) treat marker lines.
2. **A page marker.** Propose the form, for example `<!-- page: 12 -->`, with the page's label as the source names it ("12", "xii", "A-3").
   - Where it sits: a line of its own, or inline mid-paragraph, since page breaks often fall mid-sentence in EPUB, PDF, and DAISY.
   - What the reader does with it: never spoken, never splits a paragraph or sentence, and a position maps to the page that holds it.
   - Inline marker against a sidecar index. Weigh what each does to existing books' stored positions, to Edit Text, and to export (the export walker must drop it, or later carry it for braille's print page indicators).
   - Recommend one.
3. **Each format's pages.** For each, say what the source holds, what TextMouth's parser keeps today, and what it would take:
   - **EPUB 3:** the nav `page-list`, and `epub:type="pagebreak"` / `role="doc-pagebreak"`. **EPUB 2:** the NCX `pageList`.
   - **PDF:** each PDFKit page and its label (`PDFPage.label`), and how the PDF reader extracts text now.
   - **DOCX:** `w:br w:type="page"`, `w:pageBreakBefore`, section breaks, `w:lastRenderedPageBreak` (Word's last layout), and numbering restarts (`w:pgNumType w:start`). Which to trust.
   - **DOC, RTF, ODT, and Word 2003 XML through textutil:** does textutil's HTML keep page breaks (RTF `\page`, a DOC page break, an ODT break)? Find out by converting copies of the samples in `TestData/format-samples/`, in your own folder under the repository's gitignored `build/pages-research/`, with `/usr/bin/textutil -convert html`, and say what comes out.
   - **DAISY 2.02** (ncc.html page spans), **DAISY 3 and NIMAS** (NCX `pageList`, DTBook `pagenum`), and DAISY audio books' page targets.
   - **Braille BRF and PEF:** the braille page numbers, which `BraillePageAnalyzer` already finds, and print page indicators.
   - **Plain text** (form feeds) and **HTML**: say whether they are worth doing.
   - **Audiobooks:** none, except DAISY.
4. **Navigation today.**
   - The navigation units the reader has, and how Next and Previous and rewind and fast-forward choose theirs (`ReaderViewModel+Navigation.swift`, `KeyboardShortcut.swift`, `MenuCommands.swift`, `SettingsPolicy.swift`, `PlaybackControlsView.swift`).
   - The keyboard scheme, and free keys for Next Page, Previous Page, and Go to Page… (`KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` in the main checkout, and the duplicate-controls rule: a new command must not duplicate an existing one).
   - Where Am I's sentences (`ReaderViewModel+WhereAmI.swift`).
   - The reader screen's status area, where an optional "Page 12 of 300" would go.
   - Propose page as a navigation unit "like the others", a Go to Page… sheet (its words, label, hint, and refusal), and two settings (show the page on the reader screen; say the page in Where Am I), with their defaults.
5. **Existing books.** How books already in the library could gain pages: re-reading on a parser version bump (the EPUB metadata refresh is a pattern), a command, or new imports only. What that does to places and bookmarks, and how T06's relocator could keep them. Recommend the safe course.
6. **Samples.** Which samples in `TestData/format-samples/` have pages, and which must be made: an EPUB 3 with a page-list, an EPUB 2 with a pageList, a PDF with labels, a DOCX with breaks, a DAISY with pagenums, and a BRF.
7. **Risks.** Performance on a 2,000-page PDF, page labels repeated or out of order, and pages that begin mid-word, among others.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b research/pages main`.
- **Commits.** Write only the research document. Its commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Do not** build with xcodebuild, run tests, push, or touch `~/.TextMouth`. Running `textutil` on copies of the samples in your own `build/pages-research/` folder is fine. Never play a sound.
- **Others at work.** Two other agents are working: `racefix` (the reader's load against a library move) and `brailleemphasis` (emphasis through braille). Plan around their files, and do not edit any.

## The report (your final message, at most 30 lines)
- The document's path and commit.
- The recommended schema, in two lines.
- The PG items as one line each.
- The team plan in five lines.
- The questions for the user, with their recommended answers.
