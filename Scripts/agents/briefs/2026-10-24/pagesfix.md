# Brief: three small pages fixes after the October 24 verification

You are `pagesfix`, an Opus agent. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display. A sentence that says something false about where the listener is counts as a bug here: nobody sees the screen.

Read `common.md` beside this file first: its rules apply to you, except where this brief says otherwise.

## Setup
Your worktree is made from main. Run `git checkout -b fix/pages-oct24 integrate/oct24`, and check that `git merge-base --is-ancestor 1d7cb5a5 HEAD` succeeds. `integrate/oct24` holds pages/polish and pages/braille merged, with their review fixes. The verifier's report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/verify-pages-report.md`; read its "New problems" and "Not from these fixes" sections.

## Fix these, each a small commit with its test
1. **A false "has no words" during playback** (`ReaderViewModel+Pages.swift:259-262`).
   - The code takes "the cursor is not on the page asked for" to mean "the page has no words".
   - While a text book plays, Go to Page to a page whose rest of chapter is skipped (skipped notes, for example) restarts speech (`ReaderViewModel+Navigation.swift:959`). That moves the cursor to the next chapter with speech (`ReaderViewModel+Playback.swift:664`), so it says "Page 40 has no words, so the cursor is on page 52." when page 40 has words.
   - Decide "no words" from the pages themselves: the page's own range holds no word.
   - When the cursor is elsewhere for another reason, say only what is true. Name the reason if the code knows it, in the style of the existing sentences. Otherwise say the page the status row names.
   - Confirm the scenario in a test before you fix it.
2. **A self-contradictory sentence for a blank page that shares its label.** `GoToPageTests.swift:237` pins "Page 3 has no words, so the cursor is on page 3, the second page labelled 3." Say which page of the label is blank, for example "The first page labelled 3 has no words, so the cursor is on the second page labelled 3." Typing 2 can likewise reach a blank "2" and say "Page 2 has no words" while the other page 2 has words. You choose the words, keep them short, and pin each in a test.
3. **A BRF whose only form feed is at its start or its end** counts as marking its pages. A six-page BANA file became one page labelled "6", and the page numbers of pages 1 to 5 stayed in the text, where they are read aloud. Treat form feeds that stand only at the start or the end as no form feeds, so the rule for a BRF without form feeds decides. Test the six-page file both ways.

## At the end
In one `run-area.py` invocation, run `GoToPageTests`, `PageNavigationTests`, the braille page classes, and the reader-text and braille areas. Also run `make lint-tests LINT_BASE=main` and `make lint-a11y`. Delete your build folder, unregistering its app first as `common.md` says.

## Your report (at most 15 lines)
- Each commit.
- The counts and the lint results.
- Every sentence a listener hears that is new or changed, in full.
