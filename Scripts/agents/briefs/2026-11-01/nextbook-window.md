# Brief `nextbook` (November 1, 2026): the reader window goes on to the next book

You are `nextbook` (Sonnet). You build one feature for version 0.2.5 on the branch `feature/nextbook-window`. Make the branch from local main by name: `git checkout -b feature/nextbook-window main`. Your worktree may start on an older commit, so name main explicitly.

## The user's request, November 1, in their words

"the opening of new windows when completing a book in the reading list or similarly configured folder or / feed item seems to open a new window for the item moved to, though it correctly moves to the new item. I would want it to iether close the old window once the new one was moved to, or even better "rebuild" the original window to be have the new book as the active item viewed (if these are functionally the same and the first is easier do that), but the second rebuild I think wwould also allow for example go to next/previus episodes in feeds or normal folders, a setting for which would be my secondary request for 0.2.5. I would want a global setting for the behavior of moving from book to book for windows and a local one for feeds and folders if the behavior is set to move to another book."

The user is blind and uses VoiceOver and a braille display. Every control must be reachable by keyboard and have a spoken label, value, and hint. Every announcement must say what happened.

## Rules

- Read `AGENTS.md` first, especially "The user's standing rules" and "How a task agent works". The one exception is building: you build only through the build train, below.
- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library, in a test, an experiment, or a check.
- Never push, merge, or install.
- **Tests:**
  - no test may trap: no force unwrap, unguarded subscript, or over-fulfilled expectation;
  - no test may play sound, record, or decode Ogg through Apple's frameworks;
  - no test may touch `UserDefaults.standard`.
- Every `rm` takes literal paths, never a shell variable: a variable path waits on a permission prompt the user may not see for hours.
- Scratch files begin with `nextbook-`.
- **Commits:** one logical change per commit, each with its tests. Every function and non-obvious block gets a comment. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- **Markdown:** edit no `*.md` file except your design note, which you stage with `git add -f`. A documentation pass follows your merge.
- **The message board:**
  - register as `nextbook`, with your branch and the files you will edit;
  - read your inbox before each commit and before your report (`python3 -I .claude/skills/agent-bbs/scripts/bbs.py inbox nextbook --unread`);
  - post a short `commit` notice after each commit;
  - release your claims at the end.

## Building and testing: the build train only

The Mac has 8 GB of memory and froze under agents' builds on October 31. The orchestrator holds every build slot, so a build you start yourself waits forever. A build train runs every hour and half hour instead. It merges every waiting branch onto `train/base` (main), builds once, and runs the union of the tests asked for.

1. Commit your work. A new test file needs `xcodegen generate` (`/opt/homebrew/bin/xcodegen`) and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed.
2. Queue it, naming test classes and `Scripts/test/run-area.py` areas (`python3 -I Scripts/test/run-area.py --list` lists the areas):
   `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/build-train.py request --agent nextbook --branch feature/nextbook-window --classes ClassA,ClassB --areas playback-end,reading-list,windows`
3. Wait with `python3 -I .claude/skills/agent-bbs/scripts/bbs.py watch nextbook --timeout 1800`. Your result is posted to you, with a topic beginning "train". It is also written to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/train/results/nextbook.md`, which names each failure and the log.
4. Batch your work, so each train tests as much as possible. While a train runs, write the next commit's code and tests.

## What happens today

The orchestrator read this; check it yourself before relying on it.

- **The reader window.** `TextMouth/App/TextMouthApp.swift`, about line 49, declares it: `WindowGroup("Book Reader", id: BookReaderWindowView.windowID, for: UUID.self) { $bookID in ... BookReaderWindowView(bookID:...) }`. `BookReaderWindowView` (`TextMouth/Views/Reader/BookReaderWindowView.swift`) makes its `ReaderViewModel` as a `@StateObject` in `init`. It registers its `NSWindow` with `LibraryWindowRouter` in `onWindowFound`, and closes the reader in `onDisappear`.
- **Going on at a book's end.**
  - `goOnPastThisBook(to:in:startingWith:...)` in `TextMouth/ViewModels/ReaderViewModel+GoingOn.swift` calls `handOverToNextBook` (`ReaderViewModel+Playback.swift`, about line 2904).
  - That announces "Starting: <title>", then asks for the next book after `continueToNextBookDelay` through `NextBookHandOver`.
  - Asking means `continueToNextBook(_:)` (about line 2971: an autoplay request, then `.continueToNextBook` posted) or `continueThroughReadingList(to:)` (`ReaderViewModel+ReadingList.swift`).
- **Next and Previous in Reading List.** `goThroughReadingList(_:)` in `ReaderViewModel+ReadingList.swift` goes through `continueThroughReadingList` or `openFromReadingList`, which posts `.openBookWindow`.
- **Opening the window.** Both notifications reach `LibraryWindowRouter` (`TextMouth/Services/LibraryWindowRouter.swift`) and a Library window's `ContentView` (`TextMouth/Views/ContentView.swift`, about line 361). That calls `openWindow(id: BookReaderWindowView.windowID, value: bookID)`: a new window opens, or the book's window comes forward. The old window stays open. That is the bug.
- **A feed's next episode not yet downloaded** is `.episodeToDownload`. `waitForNextEpisode` downloads it, and the old reader starts it when it arrives.
- **A feed's or folder's options.** `ListeningOptions` (`TextMouth/Models/ListeningOptions.swift`) holds `continuation`, `skipsFinished`, and `predownloadsNext`. It decodes leniently, and standard options are never stored. Related code: `EndOfBookRule` decides which setting wins, `ListeningOptionsWording` holds the words, and the controls are in `FolderSettingsSheet` and Feed Info.
- **The global setting.** Settings, the Playback tab, "When book ends" (`EndOfBookBehavior`, `SettingsViewModel.swift` line 18; the picker is in `SettingsView.swift`, about line 421). Settings mirror to config.json: see `ConfigSyncTests` and how an existing enum setting is mirrored.
- **Closing a reader.** `ReaderViewModel.close()` (`ReaderViewModel.swift`, about line 2146) does all of this:
  - it stops playback and saves the place;
  - it clears and closes Now Playing;
  - it stops the sleep timer it owns;
  - it unregisters the open book;
  - it releases the book's memory.

## What to build

These are the recommended answers in the main checkout's `humanQuestions/2026-11-01.md`, which your worktree does not have. If the orchestrator sends you different answers, follow those.

1. **The global setting.**
   - In Settings, the Playback tab, just below "When book ends": a pop-up button "Open the next book in", with "This Window" (the default) and "A New Window".
   - It is mirrored in config.json like the other Playback settings, under a key you choose that follows their naming.
   - Its hint says what it does.
2. **Switching the window ("This Window").** The window the listener is in shows the next book instead of a new window opening.
   - The mechanism: `BookReaderWindowView` is given the scene's `$bookID` binding, or a closure that sets it, and the reader asks it to show the next book's ID.
   - Give the view `.id(bookID)` in the scene. Without it, SwiftUI keeps the old `@StateObject` and the window would go on showing the old book.
   - Every request goes before the switch, as today, so the new reader claims them once it has loaded: the autoplay request, and the reading list's request.
   - The old reader then closes as a closed window's reader does, and the window keeps its place and size.
   - "A New Window" keeps today's code path exactly.
3. **A book already open in another window.** If the next book is already open in another reader window, that window comes forward as today, and the window moved from closes. No two windows show one book. Find the open window through what the app already keeps: the router's reader windows, or the library's open-book registry.
4. **The local setting for feeds and folders.**
   - `ListeningOptions` gains an optional choice: nil is "Use the global setting". It decodes leniently like the other keys, and standard options are still never stored.
   - Feed Info and Folder Settings show it as a pop-up button "Open the next item in", beside "When an item ends", with "Use the global setting" first, then "This Window" and "A New Window".
   - It is dimmed while that feed or folder does not go on to another item: use `ListeningOptions.goesOn(under:)`. Its hint then says why.
   - The reading list does not get one; it follows the global setting.
5. **Next in Folder and Previous in Folder.**
   - Two new Navigate menu commands that go to the item below or above in the book's folder. A feed's episodes are in its folder.
   - The order is the one the end of a book follows there: reuse the succession code the end of a book uses, not a copy of it. Finished items are passed over when that folder's or feed's options, or the global ones, say so.
   - When the book was playing, the next one plays and "Starting: <title>" is said. Otherwise it only opens, with "Opening: <title>". Copy what `goThroughReadingList` does, including the pause without its sound and the sleep timer rule.
   - An episode not yet downloaded is downloaded, then goes on, as at a book's end.
   - With no item that way, say so, as the reading list commands do.
   - New `KeyboardShortcut` cases with no default keys, so the user can assign keys in the Shortcuts tab.
   - They follow the window setting: the folder's or feed's own choice, else the global one.
6. **Every move follows the setting.** That is the end of a book going on, the reading list's Next and Previous, and the folder's Next and Previous: the local choice where the move goes through a feed or folder that has one, else the global one.

## Hazards: meet each with a test or a stated reason

- **Teardown against start.**
  - The old reader's `close()` must not clear, close, or pause what the new reader started: Now Playing, its media session, or a sleep timer. Check how `NowPlayingService` owns its session (`prepareForPlayback(ownerID:)`) and `SleepTimerService.ownerID`.
  - SwiftUI may run the old view's `onDisappear` after the new view's `onAppear`, for the same `NSWindow`. Do not unregister a window that the new reader has just registered.
  - Keep `hostWindow` and the window's title right.
- **When the switch happens.** It happens only when the next book is asked for: `NextBookHandOver` asking, a reading list or folder command after its announcement, or an awaited episode arriving. It never happens earlier. The hand-over and `nextEpisodeWait` live in the old reader, so it must live until then.
- **The old book.** Its place is saved, and it ends finished exactly as today.
- **VoiceOver.**
  - The announcement ("Starting: <title>" or "Opening: <title>") must still be heard. Check that rebuilding the window's views does not cut it off.
  - After the switch, keyboard focus lands where a newly opened reader puts it.
- **Busy states.** Decide what happens when a switch is asked for in each of these cases. Prefer opening a new window, as today, over losing work. Say what you chose in the design note.
  - The reader has a sheet open: Edit Text, Book Information, Search in Book.
  - The reader has an unsaved Edit Text change.
  - The library is moving (`refuseWhileTheLibraryMoves`).
- **Failures.** If the next book is deleted, or fails to load, the window shows what a newly opened reader shows.
- **What stays the same.** `markBookOpened`, Recently Opened, and the open-book registry stay right. State restoration stays off for reader windows.

## Tests

- **The rule as a pure type,** for example `NextBookWindowRule`. Test:
  - the global setting and the local choice deciding the window;
  - the dimmed rule;
  - the already-open rule.
- **`ListeningOptions` coding:**
  - the new key round trips;
  - missing or wrong reads as nil;
  - standard options are still not stored;
  - a record without the key, as 0.2.4 writes it, still reads.
- **The setting:**
  - the default is "This Window";
  - its config.json mirror (`ConfigSyncTests`);
  - the pop-up's label, value, and hint.
- **`ReaderViewModel`, through an injected switcher:**
  - with "This Window", going on calls the switcher after the requests, and posts neither `.continueToNextBook` nor `.openBookWindow`;
  - with "A New Window", it posts as today;
  - Next and Previous in Folder: the neighbor, the ends, skipping finished items, playing or not, and an episode to download.
- **The commands:** the new `KeyboardShortcut` cases have no default key, and the Navigate menu offers them only where they can act.
- **Today's tests:** keep them passing under "A New Window", or change one only when its old expectation is the bug the user reported, and say which in your report.
- Hosted window tests often skip on this Mac. Put the logic where plain tests reach it.

## Order of work

1. **A design note.** Write `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md` in the repository's root, at most 120 lines. It covers:
   - the mechanism, with file and line references;
   - each hazard and how it is met;
   - every new sentence and label, word for word.

   Commit it with `git add -f`, then post: `bbs.py post nextbook --to orchestrator --tag question --topic "nextbook: design ready" --body "<the note's path and its three main decisions>"`. Go on building without waiting. The orchestrator writes to you if anything should change.
2. The rule type and the global setting, with their tests.
3. The window switch, and the already-open rule.
4. The local setting for feeds and folders.
5. Next in Folder and Previous in Folder.
6. **Finish.**
   - Rebase onto main if it has moved.
   - Queue one train with `--areas all` for the whole suite, then fix what fails.
   - Rerun a test that failed only under load on its own class before calling it flaky. Ask for such reruns in the next train.
   - Then report.

## Report, at most 30 lines

- your branch and each commit, with its hash and subject;
- the whole suite's exact `Executed N tests, with S tests skipped and F failures` line;
- what you could not verify, such as the real window switching on screen, which only the user can check by hand;
- your decisions on the busy states;
- every new wording, and the page under `docs/user/` each belongs on;
- the changelog caution for 0.2.5: an older TextMouth ignores the setting, and drops a feed's or folder's own choice when it next saves it.
