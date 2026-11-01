# Next book in this window (0.2.5), design note

Branch `feature/nextbook-window`, November 1, 2026. Brief: `Scripts/agents/briefs/2026-11-01/nextbook-window.md`.

## The mechanism

- **The scene** (`TextMouthApp.swift`, the "Book Reader" `WindowGroup(for: UUID.self)`) hands the view a closure that sets its own `$bookID`, and gives the view `.id(bookID)`. A new value gives the view a new identity, so SwiftUI makes a new `@StateObject` `ReaderViewModel` in the same `NSWindow` and tears the old one down.
- **The view** (`BookReaderWindowView`) stores the closure and gives it to its reader (`nextBookWindowSwitcher`) as the reader is made.
- **The reader** has one last step for every move, `showNextBook(_:under:openingANewWindowWith:)` in `ReaderViewModel+NextBookWindow.swift`. It asks the pure `NextBookWindowRule` what to do:
  - `.openANewWindow`: runs today's post (`.continueToNextBook` or `.openBookWindow`), exactly as now.
  - `.switchThisWindow`: marks the reader as switched, then calls the closure.
  - `.bringTheOpenWindowForwardThenClose`: today's post, which brings the book's window forward, then closes this reader's window on the next turn of the main queue.
- **Every request goes first**, as today: the autoplay request in `continueToNextBook`, the reading-list request in `continueThroughReadingList` and `openFromReadingList`. The new reader claims them once loaded (`claimAutoplayRequest`, `claimReadingListRequest`).
- **Who calls it.** The end of a book (`goOnPastThisBook`, through its `start` closure and `waitForNextEpisode`), the reading list's Next and Previous, and the new Next in Folder and Previous in Folder. The window choice is read when the book is asked for, never earlier.
- **Which setting.** A move through the reading list uses the global one. A move through a feed or folder uses that feed's or folder's own choice, when it has one and it goes on (`ListeningOptions.goesOn(under:)`), else the global one.

## Hazards and how each is met

- **Teardown against start.** `NowPlayingService`, the media coordinator, and `SleepTimerService` key everything by the reader's own `ownerID`: the old reader's `close()` clears, pauses, and unregisters only itself. A test checks it leaves a second reader's owner alone.
- **Unregistering the window.** The view's `onDisappear` leaves the window registered when the reader was switched (`hasSwitchedWindow`); the new view registers the same `NSWindow` in `onWindowFound`, and `registerReaderWindow` replaces any earlier entry. An ordinary close unregisters as before.
- **When the switch happens.** Only when the book is asked for: after `NextBookHandOver` asks, after the reading list's announcement, or when an awaited episode arrives. The old reader lives until then.
- **The old book.** Its place is saved and it ends finished, as today; the switch is the last step, and `close()` saves again.
- **VoiceOver.** "Starting" and "Opening" are posted before the half second's wait, as now, from the app's key window; the switch comes after.
- **Failures.** A deleted or unloadable next book shows what a newly opened reader shows; `BookReaderWindowView` already makes an "Unknown" placeholder for a missing ID.
- **Unchanged.** `markBookOpened` runs in the new view's `onAppear`; the open-book registry follows the readers' init and `close()`; reader windows are still not restored.

## Busy states: open a new window, as today, never lose work

The rule gives `.openANewWindow` (and a book already open elsewhere is brought forward as today, with this window left open) when:

- **A sheet is open** on the reader's window, `hostWindow?.attachedSheet != nil` (Edit Book Information, Search in Book, headings, bookmarks, sleep timer, voice, export, alerts). The precedent is `speechRefusalWindowStanding`.
- **Edit Text is in use** for this book (`BookTextEditSessions.isEditing`): its changes arrive through this reader.
- **The library is moving** (`dataDirectoryMove != nil`): `ContentView` refuses the open and drops the requests, which a silent switch would get around.
- **No switcher** is set (a reader made in a test, or with no window yet).

## What is new, word for word

- **Settings, Playback, below "When book ends":** a pop-up button.
  - Label: "Open the next book in". Choices: "This Window" (default), "A New Window".
  - Hint: "Where the next book opens when listening goes on from one book to another: in this window in place of the book here, or in a new window. A book already open in another window is brought forward."
  - config.json key `nextBookWindow`, the choice's name as its value, like `endOfBookBehavior`.
- **Feed Info and Folder Settings, beside "When an episode ends" and "When a book ends":** a pop-up button.
  - Label: "Open the next episode in", "Open the next article in", "Open the next item in", "Open the next book in".
  - Choices: "Use the global setting (This Window)", "This Window", "A New Window".
  - Hint: "Where the next episode opens when listening goes on from one of this feed's episodes: in this window, in a new window, or as the global setting says".
  - Hint while dimmed: "Available only while this feed's episodes go on to another episode when one ends".
  - A dimmed choice is not in effect, as the pre-download switch's is not.
- **Navigate menu, Shortcuts tab (no default keys):** "Next in Folder", "Previous in Folder".
  - Offered in a reader window.
  - Spoken: "Starting: <title>" or "Opening: <title>" (the reading list's sentences, sleep timer sentence included).
  - With no item that way: the succession's own note and a full stop: "No more books in folder.", "Every book after it in the folder is finished.", "Every book before it in the folder is finished."
  - For an episode not downloaded: "Downloading the next episode: <title>", "Downloading the previous episode: <title>".

## Order of work

1. The rule, the global setting, and `ListeningOptions`' new key, with tests.
2. The switch in the scene, view, and reader.
3. The local controls in Feed Info and Folder Settings.
4. Next in Folder and Previous in Folder.

## Open choices for the orchestrator

- The folder commands, run in a book read from the reading list, still go through the book's folder.
- A feed that stops at an item's end dims its choice, and the choice stops applying everywhere (the commands then follow the global setting).
