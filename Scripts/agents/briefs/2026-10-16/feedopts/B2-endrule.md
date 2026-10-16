# Task B2, `feedopts-endrule`: which setting wins at the end of a book, and the way it goes

Branch `feedopts/endrule`. Read `00-contract.md` first (rules 1 to 5 are this task). Tasks A and B1 are on the team branch already: `ListeningOptions`, `LibraryViewModel.listeningOptions(of:)`, `booksBeyond(_:going:)`, `nextBook(after:going:skippingFinished:)`, `BookSuccession`, `goOnPastThisBook`. **This task makes a book's end follow its feed's or folder's options**: the rule that picks the winner, the direction (below or above), and "skip finished". It does not download anything (task B3 does, for feeds).

## What exists (read by line range)

- `TextMouth/ViewModels/ReaderViewModel+Playback.swift`: `playFromTheEnd()` `:115-139`; `handleEndOfBook()` `:2497-2572` (the reading list's branch at `:2525`, the behavior at `:2534`, the `switch` at `:2544`); `continueToNextBookInFolder(...)` `:2591-2619` (after B1 it builds a `BookSuccession` and calls `goOnPastThisBook`); `effectiveEndOfBookBehavior` `:2749-2755`.
- `TextMouth/Models/EndOfBookWording.swift:73-80`: the two folder notes.
- `EndOfBookBehavior` is in `TextMouth/ViewModels/SettingsViewModel.swift:18` (`stop`, `stopAndPlayStartsOver`, `loop`, `continueNext`).
- Users of `effectiveEndOfBookBehavior`: `ReaderView.swift:823,969` (the reader settings sheet's "When this book ends" pop-up, which shows the behavior in force) and `SleepTimerView.swift:261` (the End of book hint). They follow the new rule by reading the same property; touch neither.

## What to build

1. **New `TextMouth/Models/EndOfBookRule.swift`**, pure:
   ```swift
   struct EndOfBookRule: Equatable, Sendable {
       var behavior: EndOfBookBehavior
       var direction: ReadingList.Direction
       var skipsFinished: Bool
       var predownloadsNext: Bool
       static func resolve(localRawValue: String?, options: ListeningOptions?, global: EndOfBookBehavior) -> EndOfBookRule
   }
   ```
   - A `localRawValue` that names an `EndOfBookBehavior` wins: that behavior, direction `.down`. (A name that matches no case is ignored, as `effectiveEndOfBookBehavior` ignores it today.)
   - Else the options' `continuation`: `.playBookBelow` gives `.continueNext` going `.down`; `.playBookAbove` gives `.continueNext` going `.up`; `.stop` gives `.stop`.
   - Else `global`, going `.down`.
   - `skipsFinished` and `predownloadsNext` are the options' (true when there are none), whichever layer won.
   - Document each rule in the type's comment; this is the one place the order of precedence is written in code.
2. **The reader**, in `ReaderViewModel+Playback.swift`:
   - `var endOfBookRule: EndOfBookRule`: `EndOfBookRule.resolve(localRawValue: book.localEndOfBookBehavior, options: libraryViewModel.listeningOptions(of: book), global: settingsViewModel.endOfBookBehavior)`.
   - `effectiveEndOfBookBehavior` returns `endOfBookRule.behavior` (keep the property: other code reads it).
   - `handleEndOfBook()` reads the rule once; the reading-list branch still comes first and is untouched; the `.continueNext` case passes the rule's direction and skip on. `playFromTheEnd()` does the same.
   - `continueToNextBookInFolder` takes the rule (or its direction and skip): it asks `libraryViewModel.nextBook(after: book, going: rule.direction, skippingFinished: rule.skipsFinished)`; when nothing follows, the note is `noMoreBooksInFolderNote` if `booksBeyond(book, going: rule.direction)` is empty, else `EndOfBookWording.onlyFinishedBooksInFolderNote(going: rule.direction)`.
3. **`EndOfBookWording`**: add `static func onlyFinishedBooksInFolderNote(going direction: ReadingList.Direction) -> String`: going down it returns the existing `onlyFinishedBooksInFolderNote` ("Every book after it in the folder is finished", keep that constant, tests use it); going up, "Every book before it in the folder is finished". Nothing else in the wording changes, and a feed's item says the same words as a folder's book ("No more books in folder").
4. **Tests.**
   - New `TextMouthProductionTests/EndOfBookRuleTests.swift` (pure; needs `xcodegen generate`): all of it: the book's own wins over the options and the global; the options' three continuations over each of the four globals; nil options; an unknown `localRawValue`; skip and pre-download from the options under each winner; `standard` options change nothing.
   - **Reader level**, as new methods **added at the end** of `ContinueToNextBookTests` (`ContinueToNextBookTests.swift`, its `private` fixtures `makeWorld`, `makeAudioBook`, `makeReader` are at `:710-830`; add nothing else to that file and edit no existing method): in a plain folder of three books whose folder has options set through `world.library.setListeningOptions(_:ofFolder:)` (the world's `Library` needs a `BookFolder` row for the folder; the books are in that folder):
     1. "Play the book above": the book above plays when this one ends, announcing "Starting: <title>" once; at the top of the folder it says "Finished: <title>. No more books in folder." and plays nothing.
     2. "Stop" with the global setting at Continue to Next Book: stops ("Finished: <title>").
     3. "Use the global setting" and the global at Continue to Next Book: plays the book below, as before.
     4. "Skip finished books" off: a finished book below plays; on: it is passed over; and going up with only finished books above: "Finished: <title>. Every book before it in the folder is finished."
     5. The book's own end behavior beats the folder's option; a book opened from the reading list beats both (use the list's way into a reader that `ReadingListReaderTests` shows, or `claimReadingListRequest`).
     6. `playFromTheEnd` (Play on the finished book) follows the same rule.
     7. `effectiveEndOfBookBehavior` shows the folder's option (Stop, Continue) and the book's own over it.
   - **A feed's items** (new file `FeedEndOfBookRuleTests.swift`, `FeedTestWorld`, items made as `FeedItemIndexListTests.swift:136-176` makes them; a reader as `FeedEndToEndTests.swift:125` opens one): with the feed's options set through `world.center.setListeningOptions`, the downloaded item above or below plays; "Skip finished" honored; "Stop" stops; the global Continue to Next Book still applies to a feed with standard options and plays the downloaded item below, passing over an item that is not downloaded (task B3 changes that, not this one).

## Tests to run

`EndOfBookRuleTests`, `FeedEndOfBookRuleTests`, `ContinueToNextBookTests`, `ReadingListReaderTests`, `FinishedBookReaderTests`, `FeedItemIndexListTests`, `FeedEndToEndTests`, `ListeningOptionsTests`, `IntegrationSleepTimerTests` (load-sensitive: rerun alone if it fails, report both).

## Commits

1. `EndOfBookRule` and its tests.
2. The reader follows the rule; the wording note; the reader-level tests.

## Do not touch

The reading list's code and options, `handOverToNextBook`, the autoplay requests, the download manager, `ReaderView.swift`, `SleepTimerView.swift`, and every existing test method.
