# Brief: emphasis and formatting through braille, both ways (October 21, 2026)

You are `brailleemphasis`, an Opus agent, on the branch `braille/emphasis`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display; braille is the feature they care most about.

## The request, in the user's words
Asked "Should exported braille mark italics and bold?" (question 2 of `humanQuestions/2026-10-19.md`, which is gitignored, so read it in the main checkout at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/humanQuestions/2026-10-19.md`), the user answered: "For the italix yes it should try keeping all text formatting extractable from the braille converted to the intermediate format."

So, both ways:
- **Reading braille** (BRF, BRL, PEF): keep every piece of text formatting that the braille carries and liblouis can report, such as italic, bold, underline, and script emphasis, in the book's `content.md`, the Markdown that every text book becomes. Today it is read and dropped.
- **Writing braille** (Export's BRF and PEF): pass the book's emphasis to liblouis, so UEB's emphasis indicators are written. Today an italic word comes out as plain braille.

## What exists (main, 21bcf5d0)
- **liblouis 3.39.0** runs only in the `TextMouthBraille` helper (`TextMouthBraille/main.c`), with modes check, forward, and back. `BrailleTranslator` (`TextMouth/Services/BrailleTranslator.swift`) is its only caller. The protocol is one UTF-8 paragraph per line, with long paragraphs split at blank cells, and braille as Unicode cells.
- **Back mode** already passes a typeform buffer. Without one, liblouis writes UEB's italic indicator as `\46/,`. The typeforms it fills are thrown away.
- **Reading:** `BrailleFileReader`, then `BraillePageAnalyzer`, then `BrailleBookReader` (`TextMouth/Parsers/BrailleBookReader.swift`), which writes the Markdown.
- **Writing:** Export's `ExportDocument` (`TextMouth/Services/Export/ExportDocument.swift`). Its runs carry `isEmphasis`, `isStrong`, `isCode`, and `link`. Then the BRF and PEF writers (`BrailleExportWriters`), `BrailleDocumentWriter`, `BrailleTranslator`, `BrailleLayout`, and `BrailleFileWriter`.
- **Six-dot only.** BRF and PEF are six-dot. An eight-dot cell that a table makes from an ordinary character fails the book's export by name.
- **The record.** The braille team's notes are under "## From the braille team" in `AGENT-NOTES-2026-10-04.md`, and this Mac's tables under "## From mactables" (both in the main checkout). The charter is `Scripts/agents/briefs/2026-10-19/team-braille.md`.

## Decisions (settled; say each in the code's comments where it applies)
1. **Carrying typeforms through the helper.** Extend its line protocol so that a run of typeform codes travels with a paragraph each way: back mode returns them, and forward mode accepts them. Keep it bounded, keep L1's comma safety and the catalog check, and change nothing in the helper's containment. Version the protocol in one place, so the Swift side and the helper agree.
2. **Reading.** Map what liblouis reports to Markdown that TextMouth's own reader (`TextMouth/Parsers/MarkdownParser.swift`) understands:
   - italic as `*…*`, bold as `**…**`, and both as `***…***`;
   - underline and script, or anything Markdown cannot hold, as the nearest the reader supports. Check how the DOCX, RTF, and HTML importers carry underline into content.md today, and do the same; if nothing does, carry it as emphasis, and say so in a comment.
   - Escape Markdown's own characters in the braille's text (`*`, `_`, backslash, and the like), so text never turns into formatting by accident.
   - Emphasis must never be spoken, as with every other book's Markdown. Check that the speech and the heading list see only the words.
3. **Writing.**
   - `isEmphasis` becomes the italic typeform, and `isStrong` bold (with both, both), so UEB writes its indicators: word, passage, and terminator, as liblouis decides.
   - `isCode`: try the table's computer-braille typeform only if the output stays six-dot for all four bundled tables. Otherwise leave code plain, and say why in a comment.
   - EBAE writes emphasis its own way, and liblouis knows how.
   - A Mac table without emphasis rules simply writes plain text.
4. **Round trips.** Export to BRF a book with italic, bold, and both, in each of the four bundled tables, then import it. The emphasis must come back as the same Markdown emphasis, word for word. Pin any difference that is liblouis's own, by name, as the braille team did.
5. **Existing books.** Braille books imported before this change keep their text. A rebuild that would now add emphasis to content.md may change the text under the book's places, so look at how cache rebuilds handle changed text (T06's relocator, `TEXT-ANCHORS-RESEARCH-2026-10-10.md` in the main checkout). Make sure no place or bookmark is lost; if that cannot be guaranteed, apply the new reading only to new imports, and say so.
6. **Tests.** Hermetic tests for the protocol, the mapping both ways, Markdown escaping, and the round trips.
   - no test may trap or play a sound;
   - never touch `~/.TextMouth` or `UserDefaults.standard`;
   - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b braille/emphasis main`. Register on the board as `brailleemphasis` (`python3 -I .claude/skills/agent-bbs/scripts/bbs.py protocol`), and build only through its wrapper, which `run-area.py` uses.
- **Commits.** Small focused commits with tests, each message ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Memory care in `main.c`:** bounded buffers, and no shell.
- **Disk.** Check for 4 GB free before a build. Delete build folders at the end, unregistering their app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Workers.** No subagents.
- **Never** push or merge into main.
- **At the end,** run the braille, import, and export areas and every class you touched, in one `run-area.py` invocation, plus `make lint-tests LINT_BASE=main` and `make lint-a11y LINT_BASE=main`. Do not run the full suite.
- **Another team** is starting work on pages across formats, which will touch the braille page analysis and content.md's markers. Claim your files on the board, and keep out of `BraillePageAnalyzer.swift` unless you must.

## The report (your final message, at most 40 lines)
- Each commit, with its subject.
- The protocol change, in a few lines.
- The mapping table, both ways, and what could not be carried and why.
- The round-trip results per table, and liblouis's own differences.
- What happens to existing braille books.
- The exact counts and the lint results.
- Any new words a listener hears.
- Follow-ups.
