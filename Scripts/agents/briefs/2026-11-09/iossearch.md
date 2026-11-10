# The iPhone: Search in Book, closing one book, and focus requests (November 9, 2026)

You are `iossearch`, a Sonnet worker, on branch `ios/search-1109`. First read `common.md` beside this file and follow it, except for your start commit: make your branch at tonight's integration, `git switch -c ios/search-1109 4dccd34d`, and check that `git log -1 --format=%h` prints `4dccd34d`. That commit holds today's iPhone fixes.

The iPhone app's interface (unshipped) runs in the simulator, and its tests pass. Its lead listed what isn't built. Three of those items are your work. The user is blind and uses VoiceOver and a braille display: what VoiceOver reads, and in what order, is the design.

## Read first

- In `IOS-INTERFACE-SPEC-2026-11-07.md` (at the root; read the sections you need, not all of it):
  - "Searching", at line 187;
  - the focus rules around line 99;
  - the reader's sheets.
- The lead's report: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/ioslead-report.md`, "What isn't done".
- `docs/developer/testing.md` and `building.md`: their iPhone sections.
- `docs/architecture/platforms.md`.
- The Mac's in-book search, `BookSearchModel` and what calls it. The iPhone should share its search, not copy it.

## The work, in this order

1. **Search in Book,** as the spec's "Searching" describes: the sheet, its field, the results and what each reads, a result's jump into the reader, cancelling a search, and what VoiceOver announces. Use the Mac's search model, shared through `TextMouth/Phone/` or the shared code, with Mac-hosted unit tests for what isn't a view.
2. **`PhoneSession.closeBook(id:)`.** Removing a book that is open behind the screen still closes both readers (board message #5368). Close only that book's reader, and pin it with a unit test.
3. **"Any focus event cancels a request still waiting"** (spec, line 99), so a delayed focus request can't pull focus away from where the listener moved. Pin it with a unit test of the focus policy.

## Checks

- **Simulator passes:**
  - At most three in all, each with every XCUITest and unit test. Fix everything you can by reading before each pass.
  - Each through `run_locked.py`, with `-derivedDataPath /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/DerivedData-ios.noindex`.
  - iPhone 17 only, and make no new devices. Run `xcrun simctl shutdown all` after each.
  - Give each pass's result bundle a new name.
- **Never press Play, never type, and nothing that makes a sound.** The simulator plays through the Mac's speakers, and the software keyboard clicks.
  - So an XCUITest must never type a search. Give the search sheet a debug-only launch variable that fills in its field.
  - Test what the sheet reads, its order, and a result's jump.
- **The train** for the Mac-compiled Swift and its tests: `--areas phone,accessibility,support`, and every class you change. Type-check your tests on your commit first, as `common.md` says.
- Your report gives each XCUITest's result, and every audit finding on the new sheet in the audit's own words.
