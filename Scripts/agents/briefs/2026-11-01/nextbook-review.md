# Brief `nextbook-review` (November 1, 2026): outside review of the next-book window

You are `nextbook-review` (Opus), an independent reviewer. You review one branch, `feature/nextbook-window`, for correctness bugs before it is merged into main for version 0.2.5. Another agent (`nextbook`, Sonnet) wrote it. You change no code: you read, trace, and report.

## What the branch does

The user asked for it on November 1, in their words: "the opening of new windows when completing a book in the reading list or similarly configured folder or / feed item seems to open a new window for the item moved to, though it correctly moves to the new item. I would want it to iether close the old window once the new one was moved to, or even better "rebuild" the original window to be have the new book as the active item viewed ... the second rebuild I think wwould also allow for example go to next/previus episodes in feeds or normal folders ... I would want a global setting for the behavior of moving from book to book for windows and a local one for feeds and folders if the behavior is set to move to another book."

The user is blind and uses VoiceOver and a braille display. A wrong or missing announcement, a control without a spoken label, value, and hint, or focus lost after a change is a real bug for them, not polish.

- **The branch:** base main c91389e7, tip 1d1c8790, 8 commits, about 1,800 lines in 35 files.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md` in the repository root. Read it first.
- **The author's brief:** `Scripts/agents/briefs/2026-11-01/nextbook-window.md`. Its "Hazards" section lists what the author was asked to meet; check each one yourself rather than trusting the tests.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library, for any reason: not to look at a real book, not as a fixture, not in a check.
- **Do not build or run tests.** The Mac has 8 GB of memory and froze under agents' builds on October 31; the orchestrator's build train is the only builder. Verify by reading and tracing the code, and by Apple's documentation.
- Change nothing in any worktree but your own, and commit nothing. Never push, merge, or install.
- Every `rm` takes literal paths, never a shell variable.
- For SwiftUI and AppKit behavior, prefer Apple's documentation (developer.apple.com) and say when a claim rests on behavior the documentation does not settle.

## Getting the code

Your worktree starts on main. The branch is checked out in the author's worktree, so check out its tip detached in yours:

```
git checkout --detach 1d1c8790
git diff --stat c91389e7...1d1c8790
```

Read the whole diff, then the code around it that it depends on.

## Where to look hardest

These are the risks of the change. They are places to look, not conclusions: trace each one through the code and say whether it is sound.

1. **The switch itself.** `TextMouthApp`'s reader `WindowGroup(for: UUID.self)` now sets its `$bookID` binding and gives the view `.id(bookID)`. Check what Apple documents for changing a `WindowGroup`'s presented value, and what follows for:
   - `openWindow(value:)` of the new book and of the old one afterwards;
   - window restoration;
   - the window's title.
2. **The old view leaving, the new one arriving, on one `NSWindow`.** SwiftUI may run the old view's `onDisappear` (and the old reader's `close()`) before or after the new view's `onAppear`. In both orders, check everything the new reader sets up against everything the old one tears down:
   - `LibraryWindowRouter`'s registry of reader windows;
   - `libraryViewModel.openBookIDs` and `markBookOpened`;
   - `hostWindow`;
   - Now Playing and its media session (`NowPlayingService`, `activeOwnerID`);
   - remote commands;
   - the sleep timer (`SleepTimerService.ownerID`);
   - the pending autoplay and reading-list requests the new reader claims as it loads;
   - observers, and saving the old book's place and finished state.
3. **The old book.** It must end saved exactly as closing its window saves it: its place, its finished state, Recently Opened. This holds both at the end of a book and for Next or Previous in Folder or in Reading List from the middle of a book, playing or not.
4. **When the window does not switch.** `ReaderViewModel+NextBookWindow.swift` and `NextBookWindowRule` decide between switching, opening a new window, and bringing an open window forward and closing this one. Check:
   - whether `switchingTheWindowCouldLoseWork` sees every state in which switching could lose work: SwiftUI sheets, alerts, confirmation dialogs, popovers, file panels, an app-modal window, text being typed in a field of the reader, an Edit Text session, the library moving;
   - the closed-window case: Command-W in the half second between "Starting: <title>" and the next book being asked for;
   - the bring-forward-then-close path, which closes this window on the next turn of the main queue.
5. **Next in Folder and Previous in Folder** (`ReaderViewModel+FolderNavigation.swift`, the `EpisodeDownload` changes):
   - whether the order and the passing over of finished items match what the end of a book follows in that folder or feed;
   - the two ends of a folder, a book at the top level of the library, a book read from the reading list, and an episode that must download first;
   - the episode wait's new `fromFinishedBook` and `plays` paths, including the reader closing or the listener moving on during the download;
   - the messages each case speaks.
6. **Settings.**
   - The global `nextBookWindow`: `SettingsViewModel`, `SettingsPolicy`, `ConfigService` and config.json, its default, and an unknown or missing value.
   - The feed's or folder's own choice in `ListeningOptions`: its coding and an older file without it, equality, and whether a dimmed choice is ignored everywhere it is read.
   - The new pickers' VoiceOver label, value, and hint, dimmed and not.
7. **Shortcuts.** `KeyboardShortcut.swift`'s two new actions with no default keys: names saved on disk, migration, the menu items' enabled state. Check whether the test edits that let actions have no default keys hide anything else.
8. **VoiceOver through the rebuild.** Check two things:
   - whether "Starting: <title>" or "Opening: <title>" is posted in a way that survives the window's views being rebuilt;
   - where keyboard focus lands afterwards, compared with a newly opened reader.
9. **The tests.**
   - Do the new tests (`NextBookWindowTests`, `NextBookWindowReaderTests`, `EpisodeDownloadContinuationTests`, and the sheet tests) exercise the real paths, or only the rule?
   - Does any test trap, play sound, record, decode Ogg, touch `UserDefaults.standard`, or reach the live library?
10. **The author's known limits.** Judge whether each one should be fixed before the merge:
    - a failed or cancelled download after Next or Previous in Folder speaks the end-of-book sentences, saying "next" and "playback stopped" even when going up or when nothing was playing;
    - when the sleep timer keeps an episode from starting while it downloads, the later "Opening: <title>" does not say why;
    - the two folder menu items are enabled in every reader window, and the command says so when nothing lies that way.

## Report

Write the report to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/review-1.md` (make the folder), and return the same text as your final message, at most 90 lines.

- **Findings,** most severe first, numbered R1, R2, and so on. Give each:
  - its severity: lost or wrong data, wrong behavior, VoiceOver, or minor;
  - `file:line` at 1d1c8790;
  - the failure, as concrete steps leading to a wrong result;
  - CONFIRMED (traced through the code) or PLAUSIBLE (it rests on SwiftUI or AppKit behavior you could not settle);
  - the fix you suggest, and the test that would catch it.
- **Checked and sound:** one line for each risk above that you traced and found sound, with what you checked.
- **Questions for the user,** if any: only choices the code cannot settle.
