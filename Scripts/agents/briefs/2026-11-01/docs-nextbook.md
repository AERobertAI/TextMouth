# Documentation pass `docs-nextbook` (November 1, 2026): the next book in this window, and Next and Previous in Folder

You are `docs-nextbook` (Sonnet). You document version 0.2.5's one feature, merged into main from `feature/nextbook-window`. You change only documentation: the pages under `docs/`. You build nothing and run no test.

Branch: `docs/nextbook`, made from local main by name (`git checkout -b docs/nextbook main`). Your worktree may start on an older commit. The orchestrator's launch message names the merge commit.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Never push, merge, or install.
- Every `rm` takes literal paths.
- `*.md` is gitignored except README.md, AGENTS.md, ARCHITECTURE.md, CLAUDE.md, and the pages under `docs/`. Stage pages under `docs/` normally.
- **Commits.** One commit per part below. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- **Write for the user,** who is blind and uses VoiceOver and a braille display.
  - Use plain sentences, headings, and lists.
  - Give every control's spoken label, value, and hint exactly as the code has them.
  - Quote every announcement exactly from the code. Never write a sentence the app does not say: find it in the code first.
- **Match each page's style.** Read a page's surroundings before adding to it, and keep its structure. These pages state facts in long, exact bullets, so add to the bullet a fact belongs in rather than starting a new section.

## Sources

- **The design note,** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, in the root of the repository.
- **The code at the merge.** The wordings live in:
  - `TextMouth/Models/NextBookWindow.swift`;
  - `TextMouth/Models/FolderNavigationWording.swift`;
  - `TextMouth/Models/EndOfBookWording.swift`;
  - `TextMouth/Views/NextBookWindowPicker.swift`;
  - `TextMouth/Views/Settings/SettingsView.swift`;
  - `TextMouth/Views/Feeds/FeedInfoSheet.swift`;
  - `TextMouth/Views/Library/FolderSettingsSheet.swift`;
  - `TextMouth/App/MenuCommands.swift`;
  - `TextMouth/Models/KeyboardShortcut.swift`;
  - `TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift`;
  - `TextMouth/ViewModels/ReaderViewModel+FolderNavigation.swift`;
  - for the sleep timer: `TextMouth/Models/SleepTimerHandOverWording.swift`, `TextMouth/Services/SleepTimerService.swift` (from "Held for the Next Book" on), `TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift`, and `TextMouth/ViewModels/ReaderViewModel+BookMoves.swift`.
- **The review and fix reports,** in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/`. Where a fix changed a sentence, the code wins.
- **The user's questions and answers,** numbered as below: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/humanQuestions/2026-11-01.md`. Read it; never change it.

## Part 1: the user's pages

- **`docs/user/reader-windows.md`.** Add to its account of When a book ends, and to its account of the reading list's Next and Previous:
  - where the next book opens: in this window, which then shows it in place of the old book, or in a new window;
  - which moves follow the setting;
  - a book already open in another window coming forward while this window closes;
  - the cases in which a new window opens all the same, from `switchingTheWindowCouldLoseWork`;
  - that the old book is saved as closing its window saves it.

  Then the sleep timer, which now goes on with listening (the user asked on November 1 that it "move still running to the new book without a new window opening"). Rewrite every sentence the change makes untrue:
  - "One timer serves the whole app, and it belongs to the reader window that set it";
  - "With a sleep timer in effect in the window, no next book starts";
  - the episode wait's sleep-timer sentence;
  - the reading list's "A sleep timer set in that window keeps the next book from starting" and its "Opening: Dune. Not started because of the sleep timer." example.

  Say what is true now, from the code:
  - a running timer goes on to the next book, in this window or a new one, and stops that book when it runs out; its countdown is never restarted;
  - the timer waits for the next book however long that book takes to open, a download from iCloud included, and closing the old window meanwhile does not stop it;
  - an episode that must be downloaded first is different. While it downloads ("Downloading the next episode: <title>", or Next or Previous in Folder's "Downloading …"), the timer stays the old window's own, and it goes on with the move once the episode arrives. So closing the old window during that download ends the wait, and the episode does not start; it also stops the timer, as closing the window a timer belongs to does. Sources: `ReaderViewModel.close()`, and the design note's "A move cancelled before it asks leaves no trace";
  - a move that only opens its book ("Opening: <title>") takes the timer with it too. So with A New Window, or a new window opened because this one was busy, playing the old window's book afterwards plays it without the timer (question 18);
  - a timer set for the end of the heading or the book that runs out at a book's end still ends listening there, but one set after a book has ended goes on with the next book (questions 11 and 14 in the user's questions of November 1);
  - what happens when the timer runs out, or begins to fade out, before the next book starts: the fade runs out and the next book does not start, even if you close the old window or press Pause during the fade; only Restart Sleep Timer changes that, as described below;
  - when the next book cannot be opened, the timer is cancelled, and VoiceOver says "Sleep timer cancelled, because the next book could not be opened.":
    - after the reason the book did not open, for a book that failed to load, a download from iCloud that stopped or failed, and a book deleted meanwhile;
    - at once when the Library refuses to open the book;
    - list the cases exactly as the code names them, with `SleepTimerHandOverWording.afterTheReason` for the wait;
  - closing the next book's window while it is still loading cancels the timer without a word, as closing the window a timer belongs to does (question 15);
  - Restart Sleep Timer, from its shortcut or the AirPods gesture, while the timer is on its way to the next book: a minutes timer starts again at its full duration and still goes on with the move, even one that had begun to fade out, whose fade ends; the book you left does not resume, the next book plays as its move said, and "Timer reset." is said (`SleepTimerService.restartHeld()`);
  - Next or Previous pressed while the timer fades out ends the fade and the timer, as Pause does, and the book moved to starts; "Sleep timer cancelled, because you moved to another book while it faded out." follows "Starting: <title>", or follows "Downloading …" for an episode Next or Previous in Folder downloads first (question 13);
  - a second move made before the first move's book has started replaces the first. Examples are a second Next or Previous, a command pressed just after a book's end has said "Starting: <title>", and, with A New Window, a press in the old window while the first book still loads (question 17).
    - The first book does not start; with A New Window its window stays open, showing it.
    - The timer goes on to the book you end up at, and that book plays when the first move would have played its book.
    - A fade under way ends as question 13 says.
    - Sources: `beginMoveToAnotherBook()`, `cancelPendingMoves()`.

  Then add Next in Folder and Previous in Folder:
  - what they go to: Next goes the way the end of the book would go on, so up in a feed or folder that plays the one above, and down when the end stops; Previous goes the other way;
  - the order;
  - Skip finished;
  - playing or only opening ("Starting: <title>" or "Opening: <title>");
  - a second press within half a second of the first goes to the same item, since the window has not switched yet; a press after that goes one further (question 16);
  - an episode downloaded first, and a later move ending the wait for it: the episode goes on downloading but does not start;
  - every sentence they speak at the ends of a folder and on a failed download;
  - that they have no keys until you give them some.
- **`docs/user/settings.md`.**
  - The Playback tab's new pop-up, just below When book ends: label, choices, default, and hint.
  - Its config.json key.
  - Next in Folder and Previous in Folder among the Shortcuts tab's navigation actions.
- **`docs/user/feeds.md`.** Feed Info's new pop-up, beside "When an episode ends":
  - its label for each kind of feed, its choices (the first naming the global choice in force), and its hint;
  - its dimmed state and that hint, worded as the "Download the next episode" checkbox's dimmed state is.
- **`docs/user/library-window.md`.** The Folder Settings sheet's new pop-up under "Listening": the same facts as for feeds.
- **`docs/user/config-json.md`.**
  - The `nextBookWindow` key in the Playback list, with its values.
  - Where a feed's or folder's own choice is kept, if the page describes that file.

## Part 2: the architecture pages

`docs/architecture/state/windows.md`, `state/reader.md`, `reading-a-book.md`, `state/feeds.md`, and `state/timers-and-statistics.md`, as each applies:

- a reader window's book changing in place: the scene's `$bookID`, `.id(bookID)`, and a new reader in the same `NSWindow`;
- `hasSwitchedWindow` and the window registry;
- `NextBookWindowRule`;
- the folder commands;
- the sleep timer held for the next book, in `state/timers-and-statistics.md`, whose sleep timer entry now says two untrue things: that a closing reader always stops a timer it owns, and that the next book starts "only when no timer of the reader's is in effect at all". Describe:
  - the hold: `hold(forBook:from:deadline:isBookOpen:)`, `markAsked(forBook:)`, `adoptHeld(forBook:as:onExpire:onFadeStep:onFadeCancelled:)`, `passOnHold(fromBook:toBook:deadline:isBookOpen:returning:)`, `restartHeld()`, `releaseHeld(forBook:reason:announcingAfter:)`, and `cancelHeld(forBook:)`;
  - the last-resort deadline (`heldTimerDeadline`, 20 minutes, `armHoldDeadline`), which acts only when no reader is open for the book and otherwise looks again a deadline later. It asks the library's registry of open readers, given with the hold as a check (`isBookOpen:`, the reader's `bookIsOpenCheck`, kept as `heldBookIsOpen`). The registry now counts a book's readers (`LibraryViewModel.registerOpenBook(_:)`, `unregisterOpenBook(_:)`, `openReaderCounts`), so a book stays in `openBookIDs` until its last reader closes. Say so in `state/windows.md` too, wherever that page describes `openBookIDs`;
  - the expiry count (`expiryCount`, `didExpire(whileOwnedBy:sinceExpiry:)`, a move's `moveExpiryMark`);
  - who may write each;
  - which timer still ends listening at a book's end (`sleepTimerEndsListeningHere`);
- every move's shared start (`beginMoveToAnotherBook()`, `cancelPendingMoves()`), in `state/reader.md`;
- the focus a switched window gets once its book has loaded, only when the play button's own trigger did not post (`SwitchedWindowFocus`, `StandardVoiceOverFocusTriggerView.focusPostCount(of:)`), in `state/windows.md`.

Read `ARCHITECTURE.md` for how those pages are kept.

## Part 3: the changelog

In `docs/user/changelog.md`, add a section `## 0.2.5 (November 1, 2026)` above 0.2.4, in that section's style, with bullets for:

- the window that shows the next book in place;
- the global setting;
- the feed's and folder's own choice;
- Next in Folder and Previous in Folder, and the way they go;
- the sleep timer going on with listening to the next book, where before it kept the next book from starting;
- the two new sentences the timer can speak: "Sleep timer cancelled, because the next book could not be opened." and "Sleep timer cancelled, because you moved to another book while it faded out."

End it with this caution, in the page's words:

> An older TextMouth ignores the new setting, opening every next book in a new window, and drops a feed's or folder's own choice the next time it saves that feed or folder.

## Report, at most 20 lines

- Your branch, and each commit with its subject.
- The pages changed.
- Any wording you could not confirm in the code.
