# Documentation for the iPhone's sheet buttons, contrast, and XCUITests (November 8, 2026)

Write the developer documentation for what `ios/fix-c-1108` changed. It is merged into `integration/iosfixc` at **3d4d6b98**, which goes to main once its suite passes. Edit Markdown only. Build nothing, run no tests, and leave the version and the changelog alone: the iPhone app hasn't shipped.

## Start

- Make your branch at the merge: `git switch -c docs/ios-fixc 3d4d6b98`, and check that `git log -1 --format=%h` prints `3d4d6b98`.
- Read the worker's two reports, which name the documentation each change needs:
  - `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/iosfixc-report-1.md`;
  - `iosfixc-report-2.md` beside it. Where the two disagree, the second and the code win.
- Then read the pages you edit and the code each sentence describes.

## What to document

1. **`docs/architecture/platforms.md`:**
   - `PhoneTextStyle`: the full-contrast colours (`PhoneTextColor`), `PhoneActionButton`, and `PhoneValueRow`, with its stacking at the accessibility text sizes;
   - `PhoneSheetButton` and `PhoneSheetButtonPlacement`: every sheet's Cancel, Close, Done, Save, and Back to Book, placed after the title so that VoiceOver reads the title, then Cancel, then the confirm button. With the system's cancellation and confirmation places, the accessibility tree read the buttons before the title.
   - Full contrast follows the recommended answer to question 2 of `humanQuestions/2026-11-08.md`, until the user answers. Undoing it is one line, which the page names.
2. **`docs/developer/building.md`:** the debug-only `TEXTMOUTH_PROBE_SYSTEM_PLACEMENT` launch variable, and what `ToolbarPlacementProbeUITests` records with it.
3. **`docs/developer/testing.md`:**
   - the audit findings still open, each with what is known of its cause;
   - the accepted kind of finding: Dynamic Type on top-bar buttons, which iOS draws;
   - the audits that report without failing;
   - `LargeTextUITests`;
   - the probe test;
   - Book Information's test expecting "Author", the word the form uses for an EPUB.
4. **The spec**, `IOS-INTERFACE-SPEC-2026-11-07.md`, staged with `git add -f`:
   - where it lists Book Information's fields as "Book title" and "Book author", say what the code shows for each kind of book;
   - where it orders a sheet's toolbar, say that the buttons come after the title.

## How to write, the rules, and the report

Follow the sections "How to write", "Rules that every agent follows (word for word)", and "Your report" of `Scripts/agents/briefs/2026-11-08/docsios.md`, beside this file, exactly.
