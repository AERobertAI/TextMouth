# Task E, `feedopts-foldersheet`: the Folder Settings sheet

Branch `feedopts/foldersheet`. Read `00-contract.md` first. Task A is on the team branch (`ListeningOptions`, `LibraryViewModel.listeningOptions(ofFolder:)` and `setListeningOptions(_:ofFolder:)`, `ListeningOptionsWording`, `EnumSettingRule.storedValue(in:)`). **Build the sheet and its model; do not present it from the library window** (task F does that, in `LibraryView.swift`, which you do not touch). Your tests host the sheet directly.

A plain folder has no sheet today: Command-I on a plain folder's row speaks its full information (`LibraryInfoRow.swift:66-77`; `LibraryInfoSpeakerTests.swift:388,754` pin it). **Leave that as it is.** Whether Command-I should open this sheet is a question for the user, not for you.

## What the sheet is

Titled with the folder's name (the heading, with the header trait). Under it, the folder's facts as read-only labelled values, a braille display reads them as text, VoiceOver reads each as one element ("Books, 12 books, 3 unopened"). Then a "Listening" heading and the two listening options. Then a Done button that Return and Escape both reach.

Facts (labels are exact; the values are the words Speak Info speaks, from the same functions, see below):

| Label | Value | Shown |
| --- | --- | --- |
| Location | the parent folder's path, or "Library Root" (`LibraryFolderOption.rootLabel`, `LibrarySheetViews.swift:294`, the New Folder sheet's word for the top level) | always |
| Books | "12 books, 3 unopened" (`CountWording.books`, unopened as `LibraryInfoWording.briefParts(of: FolderInfoFacts)` says it) | always |
| Subfolders | "2 subfolders" | when it has any |
| Feeds | "2 feeds" | when it has any |
| Time remaining | "14 hours, 3 minutes remaining in total" (`TimeFormatting.spoken`) | when known |

**Do not copy `LibraryInfoWording`'s phrases**: `LibraryInfoWording.swift:224-258` builds them inside `briefParts(of:)` and `fullParts(of:)`. Extract the four phrases (books with unopened, subfolders, feeds, time remaining) into small `static func`s of `LibraryInfoWording`, make `briefParts`/`fullParts` use them, and use the same functions in the sheet. Speak Info's words must not change (`LibraryInfoWordingTests`, `LibraryInfoSpeakerTests` pin them and must stay green, unedited). The facts come from `FolderInfoFacts(_:library:feedFolders:wordsPerMinute:)` (`LibraryInfoRow.swift:192`).

Listening options (from `ListeningOptionsWording`, noun `.book`): a pop-up button "When a book ends" with the four choices of `continuationTitle` (the first "Use the global setting (<the global When book ends choice>)"), and a checkbox "Skip finished books". No third control: a folder's books are on this Mac already, so "Download the next episode" is a feed's alone.

If the folder is gone while the sheet is open (deleted in another window), the sheet shows `FolderSettingsWording.folderGone` and Done only, as `FeedInfoSheet` does for a gone feed (`FeedInfoSheet.swift:192-194`).

## Files

- New `TextMouth/Models/FolderSettingsWording.swift`: `enum FolderSettingsWording`: `title` = "Folder Settings" (the sheet's navigation title), the five labels above, `listeningHeading` = "Listening", `done` = "Done", `folderGone` = "This folder is no longer in the library." Each with a doc comment.
- New `TextMouth/Views/Library/FolderSettingsSheet.swift`:
  - `@MainActor final class FolderSettingsModel: ObservableObject, Identifiable` with `init(folderID: UUID, library: LibraryViewModel, feedFolders: LibraryFeedFolders, wordsPerMinute: Double, defaults: UserDefaults = .standard)`; `folder: BookFolder?` (read from `library.library.folders` by ID, so a rename shows); `facts: FolderInfoFacts?`; `continuation: ReadingList.Continuation?` and `skipsFinished: Bool` (get from `library.listeningOptions(ofFolder:)`, set through `library.setListeningOptions(_:ofFolder:)`, so each choice saves at once); `globalEndOfBookBehavior` (`SettingsPolicy.endOfBookBehavior.storedValue(in: defaults)`).
  - `struct FolderSettingsSheet: View` taking the model and `onDone: () -> Void`, observing `model.library`. Fixed frame (`.frame(width: 480, height: 420)`) with a `ScrollView` for the body, as `FeedInfoSheet` does (`FeedInfoSheet.swift:175-233`): a view that outgrows its window crashes the test host (`AccessibilityTestSupport.swift`, read `withHostedView`'s comment).
  - The pop-up as `ReadingListOptionsBar.swift` builds its pop-up (`.pickerStyle(.menu)`, label, `.help`, `.accessibilityLabel`, `.accessibilityHint` from the wording) and the checkbox as it builds its (`.toggleStyle(.checkbox)`). Each facts row is a `FeedInfoValue` (`FeedInfoSheet.swift:400`), reused as it is.
  - Done: `FeedItemBookInfoSheet.swift:82` and `FeedInfoSheet.swift:227-228` show how this app lets Return and Escape reach a Done button; follow the existing idiom and pin both keys with a test.
- Tests in a new `TextMouthProductionTests/FolderSettingsSheetTests.swift` (needs `xcodegen generate`, the regenerated `project.pbxproj` committed with it). The sheet is hosted with `withHostedView(_:size:until:_:)` and `descendants(of:as:)` from `AccessibilityTestSupport.swift`, as `FeedUICommandsTests.swift:443-490` hosts Feed Info; build the library and a folder the way `FeedUICommandsTests` builds its `Harness` (`:694`) or with a plain `LibraryViewModel()` whose `library` you set, as `ContinueToNextBookTests.swift:710` does:
  1. All wording pinned, including each fact row for a folder with books (some unopened), subfolders, a feed's folder inside it, and time remaining; rows that must be absent when empty or unknown.
  2. The model's `continuation` and `skipsFinished` save through the library (and a change back to the defaults stores nil); a change made by another window shows in the model.
  3. The hosted sheet draws: the pop-up with its four titles, the first naming the global choice; the checkbox; no pre-download control; the controls' labels and hints; the heading.
  4. Choosing in the hosted pop-up and clicking the checkbox saves.
  5. Return and Escape both reach Done (`onDone` called once each).
  6. A gone folder shows `folderGone` and Done.
  7. Speak Info's words are unchanged (the existing classes, run unedited).

## Tests to run

`FolderSettingsSheetTests`, `LibraryInfoWordingTests`, `LibraryInfoSpeakerTests`, `ListeningOptionsTests`, `FeedUICommandsTests` (it hosts sheets; a guard that the shared helpers still work).

## Commits

1. The `LibraryInfoWording` phrases extracted (no word changes), green.
2. The wording, the model, the sheet, and their tests.

## Do not touch

`LibraryView.swift`, `LibraryInfoRow.swift`'s `infoCommand`, `FeedInfoSheet.swift` (task D edits it), any existing test.
