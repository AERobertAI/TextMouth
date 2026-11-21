# Reading List books stay downloaded in a cloud library (November 13, 2026)

A second item for `rlfinished`, on the same branch, `feature/reading-list-remove-finished`, after the first item's commits. `common.md` and `rlfinished.md` still apply.

## The user's words

On November 13, 2026, at about 01:05: "Oh I forgot another reading list thing, if the main library is in the cloud keep all the reading list books downloaded."

## What exists

- **Keep on This Mac** (`docs/architecture/state/cloud-state.md`, "Books kept on this Mac"; `docs/user/cloud-library.md`): `KeptBooks.shared` (`TextMouth/Services/KeptBooks.swift`), on the main actor, holds the IDs this Mac keeps downloaded, saved in this Mac's own `Kept Books.json` (`MachineLocalPaths.keptBooks`), never in the library, since keeping is this Mac's own choice, as Finder's Keep Downloaded is.
- `LibraryCloudCommands.keep(_:in:from:)` and `stopKeeping(_:from:)` (`ViewModels/LibraryViewModel+Cloud.swift`); `LibraryCloudCommands.downloadEvictedKeptBooks(in:)`, which `LibraryCloudRefresher` calls after each refresh to download kept books the sync service evicted, with a five-minute wait after a failure (`keptBookRetryDelay`); Remove Download refuses a kept book (`BookCloudError.keptOnThisMac`); rows show and speak "Kept on this Mac" (`BookKeptNote`, `BookCloudStates.listsAsKept`); the summary counts kept books (`countKept`).

## Required behavior

1. **While the library is in a cloud location, every book on the reading list is kept on this Mac**, as Keep on This Mac keeps a book: downloaded at once if it's only in the cloud (the same announcement as Download Now's when the list's change came from the listener; none for books that arrive on the list from another Mac's sync), downloaded again when the sync service evicts it, and refused by Remove Download with a sentence that says it's on the reading list and how to let it go.
2. **Derived, not stored.** The books kept for the list are worked out from the list; `Kept Books.json` still holds only the listener's own choices. A book that leaves the list (removed, finished with "Remove finished books" on, or deleted) stops being kept for the list; a book the listener kept themselves stays kept. Nothing is ever removed from this Mac by leaving the list: as Stop Keeping on This Mac does, the download stays until the sync service or Remove Download removes it.
3. **One choice, this Mac's own:** a checkbox in the Reading List's options bar, shown only when the library is in a cloud location, "Keep these books on this Mac" (or better words of that length; the hint says what it does), **on by default**. Store it with this Mac's own files (beside `Kept Books.json`, through `MachineLocalPaths`), never in the reading list or the library, which every Mac reads: another Mac decides for itself. It is built and spoken as the bar's other controls are.
4. **What the rows and commands say:** a book kept for the list shows and speaks "Kept on this Mac" as other kept books do. Stop Keeping on This Mac is offered only where the listener's own choice keeps the book; for a book kept only because of the list, the commands offer nothing to stop, and Remove Download's refusal explains why. Book Information's cloud line, if it names the kept state, says "for the reading list" where that is the reason.
5. A library on this Mac or another local drive behaves exactly as before, and the checkbox doesn't appear.

## Tests

- The kept set: the list's books join it only in a cloud location and only while the checkbox is on; a book leaving the list leaves it unless kept by the listener; the listener's own keeps are untouched.
- An evicted list book downloads again after a refresh, as a kept book does, with the same retry wait after a failure.
- Remove Download's refusal for a list book, word for word, and Stop Keeping's absence for it.
- The checkbox: shown only in a cloud location, on by default, stored machine-locally (a library copied to another Mac's folder doesn't carry it), its label, value, and hint.
- No test reaches a real cloud drive: use the cloud tests' stand-ins (find them in the cloud test classes, and the hosted-test sandbox page).

## Report

Add this item to your report: its commits, its tests and the breaks that fail them, and the documentation each change needs (`docs/user/cloud-library.md`, `docs/user/library-window.md`'s Reading List section, and `cloud-state.md`'s "Books kept on this Mac").
