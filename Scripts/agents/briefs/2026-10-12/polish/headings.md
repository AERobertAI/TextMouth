# polish-headings: The Headings sheet's times follow a speed change (a P08 follow-up)

- Team polish; lead `polish-lead`. Your slug is `polish-headings`, and your branch is `polish/headings`, made with `git checkout -b polish/headings team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes this TODO item from "Still open after the P08 merge (October 10)": "the Headings sheet's rows do not rebuild when the speed or the new setting changes while it is open".

## What is wrong
The Headings sheet is `TextMouth/Views/Reader/HeadingNavigatorView.swift`. It keeps its rows in `@State headingItems` (about line 185). `rebuildHeadingItems()` builds them on appear, and again on a change of any of these (about lines 323 to 344):
- `displayMode`;
- `maxHeadingLevel`;
- `shown.value.headings`;
- `shown.value.skippedHeadingIDs`.

A row's time depends on more than these. `headingItems(for:displayed:allHeadings:skippedIDs:mode:)` (about lines 377 to 404) also reads:
- the reader's clock, `placeClock`, which counts a text book's words at its words per minute;
- `audioSpeed`, since an audiobook's Duration is heard at its speed;
- `namedListeningSpeed`, since the Playback setting `includeSpeedWithTimes` names the speed beside each length.

These three are in `TextMouth/ViewModels/ReaderViewModel+Jump.swift`, about lines 105 to 140 (`placeClock`, `timeCount`, `namedListeningSpeed`).

So the sheet goes stale until it is reopened: its Durations, its Time In values, and its named speeds. This happens when the listener:
- presses Increase Speed while the sheet is open (reader shortcuts act under a sheet);
- changes the setting in the Settings window, another window.

### How the sheet hears the reader
- **The snapshot.** `shown` is a `ReaderSnapshot<ReaderState>` (`TextMouth/Views/Reader/ReaderSnapshot.swift`, lines 16 to 41). It reads `ReaderState(of:)` again at each `reader.objectWillChange`, on the next main-queue turn, and republishes only a changed value (PERF30).
- **The speeds.** The reader republishes `audioSpeed`, which is `@Published` (`ReaderViewModel.swift`, about line 297). It also republishes the speech service's words per minute, which it assigns to its own published `currentWPM` (about lines 699 to 701).
- **The setting.** The reader does not republish the settings model. `SettingsViewModel.includeSpeedWithTimes` (`SettingsViewModel.swift`, about lines 250 to 256) sends the settings model's own `objectWillChange`, after storing the new value.

## Do
1. Add a small `Equatable` value to `HeadingNavigatorView`, such as `struct RowTiming`, with a `@MainActor init(of reader: ReaderViewModel)`. Comment it. It holds what the rows' times depend on:
   - `reader.timeCount` (`ReaderTimeWording.Count`, which is Equatable);
   - the listening speed the rows use, `reader.isAudioBook ? reader.audioSpeed : 1`, as `headingItems(for:...)` passes it;
   - `reader.namedListeningSpeed` (`ReaderTimeWording.ListeningSpeed?`, which is Equatable).
2. Add the value to the nested `ReaderState` (about lines 38 to 61), set in `init(of:)`. Rebuild the rows when it changes, beside the other handlers: `.onChange(of: shown.value.<timing>) { _, _ in rebuildHeadingItems() }`.
3. For the setting, which the snapshot never hears, use `.onReceive` on `viewModel.settingsViewModel.objectWillChange` with `.receive(on: DispatchQueue.main)`, so the new value is stored before you read it.
   - Rebuild only when the timing read from the reader now differs from the timing the rows were built with.
   - Keep that timing in a `@State` that `rebuildHeadingItems()` sets, so the reader's own changes keep it current too.
   - Any other settings change rebuilds nothing.
4. A rebuild must not move VoiceOver focus or the current-heading badge.
   - Leave `initialFocusHeadingID` and the badge alone.
   - The rows' identity stays `heading.id`.
5. Read `rebuildHeadingItems()` before you edit, and keep the comments' style.

## Tests
Read the fixtures' setup first. Then add these tests to `SpeedBesideTimesTests` or `HeadingSheetRecordingTimeTests` (`TextMouthProductionTests/`), whichever already builds the readers you need:
- the timing value changes after an audiobook reader's `audioSpeed` changes;
- the timing value changes after a text book's words per minute change, set the way those tests set it;
- the timing value changes after `includeSpeedWithTimes` flips. Use the test's sandboxed settings, never the user's, and put the setting back afterwards;
- `ReaderState(of:)` changes after the speed changes, so the snapshot republishes.

Add one hosted test that the Duration shown changes after a speed change, but only if `ViewsAndWindowsReaderSheetTests.swift` or `ViewsAndWindowsTestSupport.swift` already hosts the Headings sheet. Otherwise build no new hosting.

## Build and test
- Run only `SpeedBesideTimesTests`, `HeadingSheetRecordingTimeTests`, and `ViewsAndWindowsReaderSheetTests`.
- The redraw count in `ViewsAndWindowsReaderSheetTests` must not rise, since the timing does not change while a book plays. That count is load-sensitive: if it fails, rerun that class alone and report both results.
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-headings-…`.

    BBS_AGENT=polish-headings .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-headings" -only-testing:TextMouthProductionTests/SpeedBesideTimesTests -only-testing:TextMouthProductionTests/HeadingSheetRecordingTimeTests -only-testing:TextMouthProductionTests/ViewsAndWindowsReaderSheetTests > <scratchpad>/polish-headings-build-1.log 2>&1

## Do not touch
- `ReaderSnapshot.swift`.
- The other sheets' `ReaderState` types.
- The `ReaderViewModel` files, `PlaceClock`, and `ReaderTimeWording`.
- Any `*.md` file.
