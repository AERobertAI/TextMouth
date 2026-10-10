# Task brief: readinglistfollowups — the reading list's open follow-ups

Slug `readinglistfollowups`; branch `fix/reading-list-followups`. Read `common.md` beside this file first; its usage override ended at the 8:00 a.m. reset on October 10, so the normal rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count (the TODO's last "After the … merge" sentence) as your baseline.

## Why
The reading list (FR09, merged October 7 in 01197eb1 and 9a61278d) is how the user strings books together; the TODO's lines "Still open after the reading-list merge (October 7 evening)" and "Still open after the reading-list-reader merge (October 7 evening)" list what its agents left. Read FR09's entry, those lines, and the readinglist and readinglistreader agents' notes in `AGENT-NOTES-2026-10-04.md` first. The user's FR09 words: "a fifth view which in most ways will act like a manually reorderable folder view but the books can come from anywhere".

## Items, one commit each, each with its tests
1. **Move Up and Move Down are not VoiceOver actions of a row** at the Reading List (nor in a folder in manual order): add them as named accessibility actions of each book row where the order can be changed, announcing the new position ("Dune, 3 of 12"), so a VoiceOver user reorders without the menu or a drag.
2. **The edit-mode bar** offers Add to Reading List and Remove from Reading List beside Move, for the selected books, with the same announcements as the context menu.
3. **A retired book's ID stays on the list** until the next change (`removeRetiredBooks(access:skips:)`): take it off when the book leaves the library.
4. **Rebuild Library Index loses the reading list**, as it loses folder sorts: keep both across a rebuild (from the index being replaced, or from what the session holds), and say so in its message if anything could not be kept.
5. **Replace on a duplicate import gives the new copy a new ID**, so the replaced book leaves the list: put the new ID in the old one's place on the list.
6. **Import and New from Text at the Reading List** go to the last folder shown and add nothing to the list: add what they make to the end of the list, and say where the books themselves went.
7. **Speak Info** on a book on the list adds "In reading list, 3 of 12" to its brief summary (pinned wording, as `LibraryInfoWording` pins its others).
8. **A book continued to that is only in the cloud** claims its autoplay request only after it downloads and loads, so a download over 30 seconds leaves it open but not playing: keep the request while its download is under way, and let it lapse only when the download fails or is cancelled.
9. **When an open is refused while the library moves**, the autoplay and reading-list requests wait out their 30 seconds: drop them at the refusal.
10. **DRY:** `ReaderAutoplayRequests` and `ReadingListOpenRequests` have one shape that one store can serve.
11. **Comments and dead code:** the reading list's design notes in `LibraryViewModel+ReadingList.swift` describe the reader's part in the future tense and say it claims "as it finishes loading" (#1455); the `#else` copy of `ShortcutAction` in `TextMouthTests/Sources/Tests/KeyboardShortcutTests.swift` is dead and out of date.

Leave out what the user still has to decide: where a finished book's position rests (P07), and the books at their end that a list with Skip finished books off can run through one after another.

## Files you own
`LibraryViewModel+ReadingList.swift`, the reading list's model and view, the book rows' accessibility actions and the edit-mode bar in the Library views, `removeRetiredBooks`, Rebuild Library Index's reading-list and sort handling, the duplicate import's Replace path, Import and New from Text's destination at the Reading List, `LibraryInfoWording` (the reading-list part only), the autoplay and reading-list request stores, the legacy test file's dead copy, and their tests. `feedfollowups` (feed packages and lifecycle, `FileImportService.publishReadableBook`) and `feeddownloadprogress` (feed download progress beside the import overlay) are working: ask on the board before touching their files.

## Verify or report as unverified
Live VoiceOver on the new row actions and the edit-mode bar is unverified (hosted tests see no SwiftUI buttons); pin the actions' names and announcements with tests that need no window. Report the README and ARCHITECTURE wording and the TODO sentence.
