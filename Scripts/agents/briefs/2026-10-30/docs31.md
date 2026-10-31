# Documentation pass `docs31` (October 31, 2026)

You are `docs31` (Sonnet). You change only documentation: `README.md`, `ARCHITECTURE.md`, and the pages under `docs/`. You build nothing and run no test. Branch: `docs/oct31`, made from `integrate/oct30` by name (`git checkout -b docs/oct31 integrate/oct30`); your worktree may start on an older commit.

## Rules
- Never read, copy, or write anything under `~/.TextMouth`.
- Never push, merge, or install.
- `*.md` is gitignored except README.md, AGENTS.md, ARCHITECTURE.md, CLAUDE.md, and the pages under `docs/`. Stage pages under `docs/` normally, and any other Markdown file with `git add -f`.
- One commit per documented feature. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Write for a blind VoiceOver and braille user: plain sentences, headings and lists, every control's spoken label, value, and hint as the code has them. Quote every wording exactly from the code or the reports. Never invent a sentence the app does not say: read it in the code to be sure.
- Match the pages' existing style: read a page's surroundings before adding to it, and keep each page's own structure.

## Part 1, now: customizable Library views (`team/views`, merged into integrate/oct30 as 71f22891)
Sources:
- the design, `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` (in your checkout's root), whose section 9 lists every wording;
- the lead's report, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/views-lead-report.md`, which ends with the review round's changed sentences;
- the code in `TextMouth/Models/LibraryView*.swift`, `TextMouth/Views/Settings/LibraryViews*.swift`, `LibraryViewEditor*`, and `LibraryView.swift`'s picker.

Pages:
- `docs/user/library-window.md`: the View pop-up ("Library view"), the views, the Feeds view, what each built-in view lists, Go to View and Command-1 to Command-9, a view hidden or deleted while shown, and the empty sentence. Its first bullet describes the old category picker: rewrite it.
- `docs/user/settings.md`: the new Library tab (its list, the Visibility pop-up, Move Up and Move Down, New View…, Edit…, Duplicate, Delete…, Restore Default…, and the 200-view limit), and the view editor (its fields and conditions, the live count, and its errors). Also the Shortcuts tab's Go to View actions.
- `docs/user/feeds.md`: the Feeds view.
- `docs/user/config-json.md`: the `libraryViews` key and its shape, and that sorts stay in library.json.
- `docs/architecture/state/preferences.md`: the new mirrored preference and its store.
- `docs/architecture/state/library-index.md`: the `"/views/<id>"` sort keys.
- `docs/architecture/state/windows.md`: a window's view state.

## Part 2, now: braille file characters (`team/braillecodes`, merged as 0b523829)
Sources:
- the research, `BRAILLE-CODES-RESEARCH-2026-10-25.md`, section 8;
- the lead's report, `build/orchestrator/oct30/braillecodes-lead-report.md`, with its fix round's sentences at the end;
- the verifier's note, `build/orchestrator/oct30/verify-braillecodes.md`, problem B.

Pages:
- `docs/user/settings.md`: the Braille tab's "Braille file characters" pop-up, with its two codes and its caption.
- `docs/user/exporting-books.md`: the Export dialog's choice for a BRF.
- `docs/user/library-window.md`: Book Information's "Braille File Characters" row and its alert. Speak Full Info's "Braille characters: …" sentence.
- `docs/user/what-textmouth-reads.md` and `docs/user/adding-books.md`: the three codes, the recognition of Unicode braille, and the refusals ("Line 2 holds the byte 0xE9. This file may be eight-bit computer braille, which TextMouth does not read." and the UTF-16 sentence).
- `docs/user/where-your-library-lives.md`: `brailleFileCode` in a book's row and record.
- `docs/user/config-json.md`: the `brailleFileCode` key.
- `docs/architecture/state/imports.md` and `exports.md`, as they apply.
- `docs/developer/third-party-code.md`: the three vendored liblouis display tables.

## Then
Report your commits and stop, saying "parts 1 and 2 done". The orchestrator will send part 3 (the bug hunt's fixes, the test suite's changes, and the 0.2.4 changelog section) by message once that code is final.

## Report (at most 20 lines)
Your branch, each commit with its subject, the pages changed, and any wording you could not confirm in the code.
