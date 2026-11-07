# Team `iosui`: the slices (November 7, 2026, revised after the reviews)

Each slice's worker reads `iosui-workers.md` first, then its section here, then the spec's sections it names. The spec is `IOS-INTERFACE-SPEC-2026-11-07.md`, revised from the two outside reviews, which are kept in `iosui-research/` (`review-user.md`, `review-engineer.md`): read the findings your section names, by line range. Research sections are in `iosui-research/`. Find them with `grep -n "^#"`.

Every branch comes off `ios/interface`, which holds Slice 1's frame and seams: `PhoneAppModel` (with the navigation path of `PhoneRoute`s), `PhoneSession` (two readers at most, the next book, the crash guard, the snapshot, `bookInReach`, `playWhenLoaded`, `noteBookEngaged()`), `PhoneDefaults`, `PhoneLifeCycle`, `ReaderPhoneHooks` on the reader, `VoiceOverAnnouncer.collectingAnnouncements(during:)`, `PhoneAnnouncer`, `PhoneFocusPolicy`, `PhoneFocusRegistry`, `PhoneListFocus`, `PhoneReaderSheet`, the root's modifiers, and the choice sheet (`PhoneChoice`, `PhoneChoiceSheet`). Use them; don't write your own. If one is missing or wrong, post a question to `iosui-lead` and carry on with the safest choice.

Rules every slice keeps, from the engineering review:
- **No view observes `ReaderViewModel` or `LibraryViewModel` directly** where it would redraw while the book plays: read `PhoneSession`'s snapshot, or a small model of your own that republishes only on real change.
- **Every notification observer** uses `addObserver(forName:object:queue: .main)`, then `MainActor.assumeIsolated`. Never `queue: nil` with it, and never a Combine `.sink` without `.receive(on: DispatchQueue.main)`.
- **Every background task's expiry handler ends it.**
- **No Mac view is wrapped or changed.** A sheet the phone needs is rebuilt for the phone, as a small `Form` in a `NavigationStack`, over the same model calls and wording.
- **No new `@unchecked Sendable` or `nonisolated(unsafe)`.**
- **`.navigationBarTitleDisplayMode(.inline)`** on every screen, so the title comes before the toolbar.

## Slice 2: the Library

- **Worker:** `iosui-library`. **Branch:** `ios/s2-library`.
- **Spec:** "The principles", "The rules every screen follows", "The Library", "Errors, empty states, long operations", "One vocabulary".
- **Reviews:** `review-user.md` findings 4 and 10; `review-engineer.md` F11, F12, F22.
- **Research:** `research-code.md`, sections 2.1 to 2.6, 7.16 to 7.22, 7.28; `research-vo.md`, section 1.12.
- **Builds:**
  - `PhoneLibraryView`: the top, a folder, and any other view, one view over a `LibraryLocation`, in the spec's order, with the bottom bar. It becomes `PhoneRootView`'s first screen; that's your one edit there.
  - `PhoneLibraryRows`, plain: the list held as `[PhoneRowValue]` (id, label, visible lines, kind), republished only when the list's signature changes (IDs in order, titles, authors, folder counts), rebuilt on appearing, when a book stops playing, and when the view, sort, or search changes. `PhoneBookRow` and `PhoneFolderRow` take only a row value and are `.equatable()`. The Mac's labels are called, not copied: `BookRow.rowAccessibilityLabel` and its statics are in `Views/Library/LibrarySubviews.swift`. If one is private, widen it only as far as the iPhone needs, and name that shared change in your report.
  - Letter sections in a Title or Author sort with more than about 30 books, as headings, with `sectionIndexLabel` for touch.
  - Search across the whole library (titles, authors, folder names), with folder rows among the results, as the spec says.
  - The Continue row, from the snapshot and `bookInReach`. The visible Play beside it is hidden from VoiceOver.
  - Library view and Sort through `PhoneChoiceSheet`. The summary row.
  - Row actions and context menus; Move Up and Move Down; removal, by the spec's one question; Book Info (rebuilt for the phone: the spec's "The Book Info sheet").
  - Return of focus by `PhoneListFocus`. The folder's arrival words.
- **Plain, shared, tested:** `PhoneLibraryRows`, `PhoneRowWording` (the Continue row, search's count, empty states), `PhoneLibraryOffer` (which actions a row has, in which order), `PhoneLibrarySections`, `PhoneLibraryVocabulary` with `PhoneLibraryVocabularyTests` reading the Mac's source for each inline word.
- **Settings** is pushed as `PhoneSettingsView(settings:)` from `ios/s9-settings`: use a placeholder destination if it hasn't reached your branch, and name that in your report.
- **Claims:** `TextMouth/Platform/iOS/Views/Library/**` but the folder sheets, `TextMouth/Platform/iOS/App/PhoneRootView.swift`, `TextMouth/Phone/PhoneLibrary*.swift`, `TextMouth/Phone/PhoneRow*.swift`, and their tests.

## Slice 2b: the folder sheets

- **Worker:** `iosui-folders`. **Branch:** `ios/s2b-folders`.
- **Spec:** "The Library", its "Folder sheets", and "Choices".
- **Reviews:** `review-engineer.md` F3.
- **Research:** `research-code.md`, sections 2.2 and 7.20.
- **Builds:** New Folder, Rename Folder, Move Folder, Move to Folder, and Delete Folder (with its Move Contents choice), rebuilt for the phone, over the Mac's model calls (`createFolderReturningOutcome`, `renameFolderReturningOutcome`, `moveFolderReturningOutcome`, `moveBooksReturningOutcome`, `removeFolderMovingContentsReturningOutcome`, `removeFolderAndEverything`) and wording. Folders chosen through `PhoneChoiceSheet` from `LibraryFolderOption.options(in:)`. Each is a view taking the library and what it acts on, with a closure for when it's done, so Slice 2 presents it.
- **Plain, shared, tested:** `PhoneFolderSheetModel` for what each sheet decides (whether Create is enabled, the sentence said after), and `PhoneFolderVocabulary` with its vocabulary test.
- **Claims:** `TextMouth/Platform/iOS/Views/Library/PhoneFolder*Sheet*.swift`, `TextMouth/Phone/PhoneFolder*.swift`, and their tests.

## Slice 3: importing

- **Worker:** `iosui-import`. **Branch:** `ios/s3-import`.
- **Spec:** "Importing", and the parts of "One vocabulary" on Trash and the refusals.
- **Reviews:** `review-user.md` findings 8, 15, 19; `review-engineer.md` F14, F18, F23, F33.
- **Research:** `research-ios.md`, sections 7 and 8; `research-code.md`, sections 2.7, 7.23 to 7.25.
- **Builds:**
  - `PhoneAddToLibrarySheet` with one `fileImporter`, its mode chosen by the row.
  - `PhoneImportCopier`, iOS only: its own queue, never the import queue; free space checked for twice the size; the scope; `NSFileCoordinator` per file, cancellable, with a 2-minute stall limit; a scratch folder under `tmp/PhoneImport/<UUID>/` keeping the original name; then `importFiles` or `importAndOpenFiles`. Each import in a background task. The screen kept awake while an import runs in front.
  - `PhoneImportHolding`, plain and shared: URLs held until the library has started, the sweep's moment (when nothing imports and no question waits), the record of what's being imported for a killed import's sentence, the sentences.
  - `PhoneLifeCycle.openedFiles` filled through this; a book playing means import without opening.
  - The progress card, rebuilt for the phone, with the Mac's words, and the quarter announcements while no book plays.
  - The import question, rebuilt for the phone, `.interactiveDismissDisabled(true)`, from `library.importDecisions.current` and `answerImportDecision(_:with:)`.
  - The refusals in the spec's words, by `#if os(iOS)` branches in the shared wording types, and the low priority of the import's end on iOS.
  - Last, if time allows: the drop folder (`UIFileSharingEnabled`, a scan of `Documents/` at launch and on each return, folders becoming library folders). Tell the lead before you start it.
- **Claims:** `TextMouth/Platform/iOS/Views/Import/**`, `TextMouth/Platform/iOS/Services/PhoneImport*.swift`, `TextMouth/Phone/PhoneImport*.swift`, the small iOS branches in the shared import wording, and their tests.

## Slice 4: the reader

- **Worker:** `iosui-reader`. **Branch:** `ios/s4-reader`.
- **Spec:** "The principles", "The rules every screen follows", "The reader" up to "The Bookmarks sheet", "Words that say Mac".
- **Reviews:** `review-user.md` findings 1, 2, 5, 6, 9, 12, 13, 20; `review-engineer.md` F2, F15, F16, F17, F20.
- **Research:** `research-vo.md`, sections 1.2, 1.7 to 1.10, 3, and 6; `research-code.md`, sections 2.8 to 2.11, 2.15, 6.3, 7.1 to 7.7, 7.11.
- **Builds:**
  - `PhoneControlDescription`, `PhoneReaderControls`, plain: every word and trait of every reader control, for a plain `PhoneReaderState`.
  - `PhoneReaderModel`, shared and `@MainActor`: builds `PhoneReaderState` once per turn of the main queue from the real cursor; the one move path, through `performSkip(unit:forward:)`, with `cancelWhereAmIIfActive()` first, inside `collectingAnnouncements`, filling `ReaderPhoneHooks.moveForward` and `moveBackward` so the AirPods take the same path; `noteBookEngaged()` at the first move; Play's value after a paused move.
  - `PhoneControl`, iOS only: a `UIViewRepresentable` over a `UIButton`-based view that overrides the accessibility getters, each asking a closure at the moment VoiceOver asks; `accessibilityIncrement()`, `accessibilityDecrement()`, `accessibilityActivate()` returning true; and registering itself in `PhoneFocusRegistry`.
  - `PhoneReaderView`: the 19 elements in the spec's order and layout: the strip, Play, and the grid; one column at large text sizes. Never keyed by book. Focus on arrival by `PhoneFocusPolicy`. Sheets through `PhoneReaderSheet` and `PhoneReaderSheetContent` (Slice 7 owns the content; the Navigation unit's list is yours, through `PhoneChoiceSheet`).
  - `PhoneNavigationUnits`, `PhoneMoveFeedback`, `PhonePassagePolicy`, `PhoneReaderWording`, `PhoneReaderVocabulary`.
  - `PhoneBookTextView`, iOS only: Book content, with focus tracked by `accessibilityElementDidBecomeFocused` and `accessibilityElementDidLoseFocus`; Listen from Here; the Sentences rotor; paging by `accessibilityScroll`; the screen kept awake while focused; a fixed height with scrolling on; the 10-second refresh only while not focused and in front; Follow in Braille's switch read from preferences.
  - Loading and failure; the error alert from the snapshot.
  - The rotors on Play: last, behind one flag.
- **Claims:** `TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift`, `TextMouth/Platform/iOS/Views/Reader/PhoneControl.swift`, `TextMouth/Platform/iOS/Views/Reader/PhoneBookTextView.swift`, `TextMouth/Phone/PhoneControl*.swift`, `TextMouth/Phone/PhoneReader*.swift` but `PhoneReaderSheet.swift`, `TextMouth/Phone/PhoneNavigationUnits.swift`, `TextMouth/Phone/PhoneMoveFeedback.swift`, `TextMouth/Phone/PhonePassagePolicy.swift`, and their tests.

## Slice 6: the life cycle

- **Worker:** `iosui-life`. **Branch:** `ios/s6-lifecycle`.
- **Spec:** "Coming back the next day", "The sleep timer on a phone", "Silent gaps", "Saving", "Memory".
- **Reviews:** `review-engineer.md` F18 (the milestones), F28, F32, and its answer on the flush under "What's underspecified?".
- **Research:** `research-ios.md`, sections 4 and 5; `research-code.md`, sections 4.5 and 4.6.
- **Builds:**
  - `PhoneSleepDeadline`, plain and shared: what's left from a deadline, and the milestones crossed since the last tick. `SleepTimerService` under `#if os(iOS)`: the deadline, and no spoken milestones on the phone. The Mac's ticks stay as they are.
  - `PhoneLifeCycle`'s handlers: the flush at the background, on the main thread inside a background task, with its time logged; nothing at `willResignActive`; the checks on coming back (an expired timer; a refresh of Book content).
  - `PhoneBackgroundHold`, iOS only: one named background task for silent gaps, begun from `ReaderPhoneHooks.audioEnded` and ended when audio starts or the work gives up.
  - `PlaybackMemoryGuard` under `#if os(iOS)`: `os_proc_available_memory()`, stopping a book under about 150 MB while playing, never quitting, never reaching `_exit`, and idle if the first reading is 0.
  - Memory warnings and thermal state: through a closure `iosui-audio` offers on `SpeechRenderCoordinator` (`mayRenderAhead`); look-ahead renders skipped under about 300 MB, or at serious or critical thermal state.
  - Reopening at launch through `.phoneReopening`: the session's reopen decision, the reader pushed only if it was on screen, focus on Play, the title said with low priority, and the crash guard's sentence.
- **Claims:** `TextMouth/Services/SleepTimerService.swift`, `TextMouth/Services/PlaybackMemoryGuard.swift`, `TextMouth/Platform/iOS/App/PhoneReopening*.swift`, `TextMouth/Platform/iOS/Services/PhoneBackground*.swift`, `TextMouth/Phone/PhoneSleep*.swift`, `TextMouth/Phone/PhoneLifeCycle+*.swift`, and their tests.

## Slice 7: the reader's panels

- **Worker:** `iosui-panels`. **Branch:** `ios/s7-panels`.
- **Spec:** "The Bookmarks sheet", "The Headings sheet", "The Go To sheet", "The Sleep Timer sheet", "The Voice & Speed sheet", "The Book Info sheet", and "Where Am I?" for its actions.
- **Reviews:** `review-user.md` findings 7, 14, 16, 18; `review-engineer.md` F3.
- **Research:** `research-code.md`, sections 2.10, 2.12 to 2.16, 7.5, 7.6, 7.8 to 7.12, 7.28.
- **Builds:** `PhoneReaderSheetContent` and each sheet, rebuilt for the phone over the same reader functions as the Mac's, each landing focus where the spec says, with plain types for what each decides (`PhoneGoToModel`, `PhoneHeadingsModel`, `PhoneBookmarksModel`, `PhoneSleepTimerModel`, `PhoneVoiceModel`), and vocabulary tests reading the Mac's source. The bookmark's place taken when Add Bookmark opens. A bookmark with a note asks before it's removed. Preview Voice pauses a playing book. The sleep timer says its words before the book starts. Then Search in Book, if time allows: tell the lead first.
- **Claims:** `TextMouth/Platform/iOS/Views/Reader/PhoneReaderSheetContent.swift`, `TextMouth/Platform/iOS/Views/Reader/Phone*Sheet.swift`, `TextMouth/Phone/PhoneGoTo*.swift`, `TextMouth/Phone/PhoneHeadings*.swift`, `TextMouth/Phone/PhoneBookmarks*.swift`, `TextMouth/Phone/PhoneSleepTimer*.swift`, `TextMouth/Phone/PhoneVoice*.swift`, and their tests.

## Slice 8: VoiceOver

- **Worker:** `iosui-voiceover`. **Branch:** `ios/s8-voiceover`, after Slices 2 and 4 have merged.
- **Spec:** "The rules every screen follows", "The rotors", "Book content" for Read All.
- **Research:** `research-vo.md`, sections 1.1, 1.4, 1.5, 1.7, 1.10.
- **Builds:** Read All's page turn, the first thing to cut; escape on anything custom; a sweep of every screen against the spec's order; `Scripts/test/a11y-lint.py` over all of `ios/interface`; the rotors if Slice 4 didn't reach them.
