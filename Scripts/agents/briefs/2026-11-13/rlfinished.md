# The Reading List removes books as they are finished (November 13, 2026)

You are `rlfinished`, a Sonnet worker. Your branch is `feature/reading-list-remove-finished`, made at local main. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026: "Oh and there really should be an option in the reading list screen to remove books as you finish them from the list."

## What exists

- `TextMouth/Models/ReadingList.swift`: `struct ReadingList: Codable` with `bookIDs`, `continuation` (what a book opened from the list does when it ends), and `skipsFinished`, its own `CodingKeys` and a tolerant `init(from:)` (about lines 209 to 245), and `remove(_:)`, `neighbor(of:_:where:)`.
- `TextMouth/Views/Library/ReadingListOptionsBar.swift`: the options bar at the top of the Reading List, a pop-up (`continuation`) and a checkbox (`skipsFinished`), each saved with the list at once through closures the window passes. Its comment says how VoiceOver reaches each control; keep that true.
- `TextMouth/Models/ReadingListWording.swift`: the bar's words (`skipFinishedLabel` "Skip finished books", `skipFinishedHint`).
- `TextMouth/ViewModels/LibraryViewModel+ReadingList.swift` (adding, removing, and saving the list) and `TextMouth/ViewModels/ReaderViewModel+ReadingList.swift` (going on to the list's next book when a book opened from it ends).
- A book's end: `ReadingStatsService.markBookFinished(bookID:title:)` posts `.bookDidFinish` (`TextMouth/Services/ReadingStatsService.swift`, about line 551) at every end it is told of, with the book's ID under `finishedBookIDKey`; a rewind's replay of an end it already counted tells it nothing. `FeedCenter` already listens for it (`Services/Feeds/FeedCenter.swift`, about line 421): follow that pattern.
- The reading list's entry in `docs/architecture/state/` (search the pages for "reading list") says who owns it and how it is saved; read it first.

## Required behavior

1. **A third control in the options bar:** a checkbox, "Remove finished books" (or better words of the same length; the hint says it acts on books finished from then on), after "Skip finished books", built and labelled as that one is. It is saved with the list, off by default.
2. **Stored with the list, compatible both ways:** a new key in `ReadingList`'s `CodingKeys`; a list saved before it has none and reads as off; an older TextMouth reading a list with the key ignores it (check that its decoder does, and pin it with a test that decodes the new JSON with the old keys' expectations). Name `OnDiskContractTests` in your train request if the list's file is pinned there.
3. **When it is on, a book on the list is taken off the list as soon as it is finished,** whether it was opened from the list or not, through the same removal the Remove command uses (DRY), and saved.
4. **Going on still works:** a book opened from the list that ends and is removed still goes on to the book that followed it on the list (or preceded it, for the backward continuation), and "Skip finished books" still applies to the books after it. Decide the order of removal and continuation so this holds, and pin it with a test for each continuation.
5. **Nothing extra is spoken:** the end of a book says what it says today. The Reading List, if open, shows the change; a VoiceOver user who looks finds the book gone.
6. **Turning the option on leaves books finished before it on the list.** (Question for the user, built this way: should turning it on also remove the books already finished? Recommended: no, since a checkbox that deletes entries at once is a surprise.)
7. The iPhone keeps compiling (`make typecheck-ios` at 0 errors); if the iPhone shows the reading list's options, add the checkbox there only if it is one row.

## Tests

- The model: decode with and without the key; a round trip; removal on finish on and off.
- The view model: a finished book on the list is removed when the option is on and kept when it's off; a book not on the list is untouched; the list is saved after a removal.
- Continuation, for each `Continuation`: the next book is the one after the removed book; "Skip finished books" together with the new option.
- The bar: the checkbox's label, hint, and value, as the other checkbox's tests check them (find them first).

## Your report

Follow `common.md`'s report, and add the documentation each change needs (`docs/user/library-window.md` where the Reading List is described, and the architecture page that owns the list).
