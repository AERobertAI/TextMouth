# Team `iosui`: the slices (November 7, 2026)

Each slice's worker reads `iosui-workers.md` first, then its section here, then the spec's sections it names. The spec is `IOS-INTERFACE-SPEC-2026-11-07.md`, as revised from the two outside reviews. Research sections are in `iosui-research/`. Find them with `grep -n "^#"`, and read by line range.

Every branch comes off `ios/interface`, which holds Slice 1's frame: `PhoneAppModel`, `PhoneSession`, `TextMouthAppDelegate`, `TextMouthSceneDelegate`, `MagicTapWindow`, `PhoneRootView`, and the choice sheet (`PhoneChoice`, `PhoneChoiceSheet`).

## Slice 2: the Library

- **Worker:** `iosui-library`. **Branch:** `ios/s2-library`.
- **Spec:** "The principles", "The rules every screen follows", "The Library", "Errors, empty states, long operations", "One vocabulary".
- **Research:** `research-code.md`, sections 2.1 to 2.6, 2.22, 7.16 to 7.22, 7.28; `research-vo.md`, section 1.12.
- **Builds:**
  - `PhoneLibraryView`: the top, a folder, and any other view, all one view over a `LibraryLocation`, each in the spec's order. It replaces Slice 1's thin list in `PhoneRootView`. Settings is pushed, as `PhoneSettingsView(settings:)` (on `ios/s9-settings`; use a placeholder link if it hasn't reached your branch, and name that in your report).
  - `PhoneBookRow`, `PhoneFolderRow`: the phone's two-line rows, with the Mac's labels called, not copied. `BookRow.rowAccessibilityLabel` and its statics are in `Views/Library/LibrarySubviews.swift`: if one is private, widen it only as far as the iPhone needs, which is a shared change to name in your report.
  - The Continue row and its Play button, reading `PhoneSession`'s snapshot alone.
  - Library view and Sort, through `PhoneChoiceSheet`. Search. The summary row.
  - Row actions and context menus; Move Up and Move Down; removal, by the spec's one question; the folder sheets; Book Info.
- **Plain, shared, tested:** `PhoneRowWording` (the Continue row, search's count, empty states), `PhoneLibraryOffer` (which actions a row has, in which order, for a plain state), `PhoneLibraryVocabulary`, with `PhoneLibraryVocabularyTests` reading the Mac's source for each inline word.
- **Performance:** a library of 700 books must not redraw on every reading position. Rows read a value computed when the list is drawn. `LibraryListCache` already derives the list once. Nothing here observes the reader.
- **Claims:** `TextMouth/Platform/iOS/Views/Library/**`, `TextMouth/Platform/iOS/App/PhoneRootView.swift`, `TextMouth/Phone/PhoneLibrary*.swift`, `TextMouth/Phone/PhoneRow*.swift`, and their tests.

## Slice 3: importing

- **Worker:** `iosui-import`. **Branch:** `ios/s3-import`.
- **Spec:** "Importing", and the parts of "One vocabulary" on Trash.
- **Research:** `research-ios.md`, sections 7 and 8; `research-code.md`, sections 2.7, 7.23 to 7.25.
- **Builds:**
  - `PhoneAddToLibrarySheet`; `fileImporter` with `FileImportService.supportedTypes` (with `.folder` for Import Folder…).
  - `PhoneImportCopier`, iOS only: start the scope, copy under `NSFileCoordinator` off the main thread, into import staging or a scratch folder the app owns, with progress, stop the scope, and hand the local copy to `importFiles` or `importAndOpenFiles`. Each runs in `beginBackgroundTask`.
  - `PhoneImportHolding`, plain and shared: URLs held until the library has started, what's done with an Inbox copy, a small record of what's being imported so a killed import can be named at the next launch, and the sentence that says so.
  - The scene delegate's seam for opened files goes through this. Sweep `Documents/Inbox` at launch and on each return to the foreground.
  - The progress card, in the Library's list, from the Mac's `ProgressOverlay` words. Import questions, presented by the phone from `library.importDecisions.current`, in a phone version of the Mac's sheet if `ImportDecisionSheet`'s frame and three-button row can't serve.
  - The refusals, and the phone's wording for what the Mac says about Trash in these sentences, each by an `#if os(iOS)` branch in the shared wording type.
- **Claims:** `TextMouth/Platform/iOS/Views/Import/**`, `TextMouth/Platform/iOS/Services/PhoneImport*.swift`, `TextMouth/Phone/PhoneImport*.swift`, the small iOS branches in `Models/ImportDecision.swift` and the braille refusal, and their tests.

## Slice 4: the reader

- **Worker:** `iosui-reader`. **Branch:** `ios/s4-reader`.
- **Spec:** "The principles", "The rules every screen follows", "The reader" up to the sheets, "Words that say Mac".
- **Research:** `research-vo.md`, sections 1.2, 1.7 to 1.10, 3, and 6; `research-code.md`, sections 2.8 to 2.11, 2.15, 6.3, 7.1 to 7.7, 7.11.
- **Builds:**
  - `PhoneControlDescription`, `PhoneReaderControls`: plain and shared: every word and trait of every reader control, for a plain `PhoneReaderState`.
  - `PhoneControl`, iOS only: a `UIViewRepresentable` over a `UIButton`-based view that overrides `accessibilityLabel`, `accessibilityValue`, `accessibilityHint`, `accessibilityTraits`, `accessibilityIncrement()`, `accessibilityDecrement()`, `accessibilityActivate()`, and `accessibilityCustomActions`, each asking a closure at the moment VoiceOver asks.
  - `PhoneReaderView`: the 17 elements in the spec's order, with the rule that nothing observes the reader's 8 Hz.
  - `PhoneReaderModel`, shared and `@MainActor`: the moves, through `performSkip(unit:forward:)`, with `cancelWhereAmIIfActive()` as `skipForward` does, and `VoiceOverAnnouncer.collectingAnnouncements(during:)` around them.
  - `PhoneNavigationUnits`, `PhoneMoveFeedback`, `PhonePassagePolicy`, `PhoneReaderWording`, `PhoneReaderVocabulary`.
  - `PhoneBookTextView`, iOS only: Book content.
  - Loading and failure. The sheets are `PhoneReaderSheet` cases, presented by `PhoneReaderSheetContent`, which Slice 7 owns.
  - `VoiceOverAnnouncer`: `collectingAnnouncements(during:)`, and the iOS mapping of priorities.
- **Claims:** `TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift`, `TextMouth/Platform/iOS/Views/Reader/PhoneControl.swift`, `TextMouth/Platform/iOS/Views/Reader/PhoneBookTextView.swift`, `TextMouth/Phone/PhoneControl*.swift`, `TextMouth/Phone/PhoneReader*.swift`, `TextMouth/Phone/PhoneNavigationUnits.swift`, `TextMouth/Phone/PhoneMoveFeedback.swift`, `TextMouth/Phone/PhonePassagePolicy.swift`, `TextMouth/Services/VoiceOverAnnouncer.swift`, and their tests.

## Slice 6: the life cycle

- **Worker:** `iosui-life`. **Branch:** `ios/s6-lifecycle`.
- **Spec:** "Coming back the next day", "The sleep timer on a phone", "Silent gaps", "Saving", "Memory".
- **Research:** `research-ios.md`, sections 4 and 5; `research-code.md`, sections 4.5 and 4.6.
- **Builds:**
  - `PhoneSleepDeadline`, plain and shared; `SleepTimerService` under `#if os(iOS)`, computing what's left from a `ContinuousClock` deadline, with the Mac's ticks unchanged on the Mac.
  - The scene delegate's life-cycle handlers: the background flush in a background task; the checks on coming back.
  - `PhoneBackgroundHold`, iOS only: one named background task for silent gaps, begun by the reader's waits, under `#if os(iOS)`.
  - `PlaybackMemoryGuard` under `#if os(iOS)`: `os_proc_available_memory`, never quitting. Memory warnings and thermal state, skipping look-ahead renders.
  - Slowing the position timers when not in front, if a small iOS branch can do that.
  - Reopening at launch: `PhoneSession.bookToReopenAtLaunch`, pushed by `PhoneRootView`, with focus on Play and the title said with low priority.
- **Claims:** `TextMouth/Services/SleepTimerService.swift`, `TextMouth/Services/PlaybackMemoryGuard.swift`, `TextMouth/Platform/iOS/App/TextMouthSceneDelegate.swift`, `TextMouth/Platform/iOS/Services/PhoneBackground*.swift`, `TextMouth/Phone/PhoneSleep*.swift`, and their tests.

## Slice 7: the reader's panels

- **Worker:** `iosui-panels`. **Branch:** `ios/s7-panels`.
- **Spec:** "The Bookmarks sheet", "The Headings sheet", "The Go To sheet", "The Sleep Timer sheet", "The Voice & Speed sheet".
- **Research:** `research-code.md`, sections 2.10, 2.12 to 2.16, 7.5, 7.6, 7.8 to 7.12, 7.28.
- **Builds:** `PhoneReaderSheetContent` and each sheet, over the same reader functions as the Mac's, with plain types for what each decides (`PhoneGoToModel`, `PhoneHeadingsModel`, `PhoneBookmarksModel`, `PhoneSleepTimerModel`, `PhoneVoiceModel`), and vocabulary tests reading the Mac's source. Prefer rebuilding a sheet for the phone over reworking a Mac view. Where a Mac view is reused as it stands, say so.
- **Claims:** `TextMouth/Platform/iOS/Views/Reader/PhoneReaderSheet*.swift`, `TextMouth/Platform/iOS/Views/Reader/Phone*Sheet.swift`, `TextMouth/Phone/PhoneGoTo*.swift`, `TextMouth/Phone/PhoneHeadings*.swift`, `TextMouth/Phone/PhoneBookmarks*.swift`, `TextMouth/Phone/PhoneSleepTimer*.swift`, `TextMouth/Phone/PhoneVoice*.swift`, and their tests.

## Slice 8: VoiceOver

- **Worker:** `iosui-voiceover`. **Branch:** `ios/s8-voiceover`, after Slices 2 and 4 have merged.
- **Spec:** "The rules every screen follows", "The rotors", "Book content" for Read All.
- **Research:** `research-vo.md`, sections 1.1, 1.4, 1.5, 1.7, 1.10.
- **Builds:** the rotors, as a small removable piece; `.screenChanged` re-posting on arrival, and its 3 seconds; escape on anything custom; Read All's page turn, the first thing to cut; a sweep of every screen against the spec's order; `Scripts/test/a11y-lint.py` over all of `ios/interface`.
