# Task brief: unopened — an Unopened category in place of No Folder

Slug `unopened`; branch `feature/unopened-category`.

## The user's words (October 7, 2026)
"Also while I'm typing I want a bit of change to the library views, folder, all, no folder, and recent right now. I want no folder to be replaced by "new" or "unopened" catagory (should include feeds with unopened items,)"

## Context (the orchestrator's analysis; verify as you go)
- `LibraryCategory` (ViewModels/LibraryViewModel.swift, line 16) has `folders`, `allItems`, `noFolder` ("No Folder"), `recent`; the Library window's segmented "View" picker lists `allCases` (Views/Library/LibraryView.swift around line 268, accessibility label "Library category"). `noFolder` is used in `LibrarySortState.swift` (lines 40, 54: sort keys and defaults), `LibraryViewModel+FolderManagement.swift` (line 372: which books a category lists), and `Views/Feeds/FeedLibraryPresentation.swift` (line 142: `LibraryFeedsSectionRows.feeds(at:center:)`, where No Folder and Recent list no feeds). A window's chosen category may be saved (it is `Codable`): find where, and map a saved "No Folder" to the new category.
- A book is unopened while `lastOpened == nil` (`BookState.isNew` is `lastOpened == nil`). A feed's items count as unplayed while `playedDate == nil` (`FeedItemCounts.unplayed` in FeedLibraryPresentation.swift); "feeds with unopened items" means feeds whose unplayed count is above zero.
- Name the category **Unopened** (the user offered "new" or "unopened"; "New" already names imports and a feed's new episodes, so Unopened is the unambiguous word; say so in your report). Its sort key replaces `__noFolder__` with `__unopened__` and a saved sort under the old key is carried over once. Its default sort: date added, newest first (`FolderSortSetting` has `.recentDefault`; choose the right one and say why).

## Files you own
TextMouth/ViewModels/LibraryViewModel.swift (`LibraryCategory` and its uses only), TextMouth/Models/LibrarySortState.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift (the category filtering), TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Library/LibraryView.swift (only the category picker, the list filtering by category, and whatever reads `category`; another agent edits the Book Info and audio editor `onSave` region around lines 1385–1460, leave it alone), the window-state file that saves the category, and the tests: whatever references `noFolder` (grep the tests), plus a new UnopenedCategoryTests.swift. Avoid: Models/Book.swift, BookInfo.swift, LibraryViewModel+BookOperations.swift, LibraryViewModel+MetadataRefresh.swift, Services/SpeechService.swift, NowPlayingService.swift, the reader view models.

## Items, one commit each, each with its tests
1. **The category.** `LibraryCategory.unopened = "Unopened"` replaces `noFolder`; `sortSettingsKey` "__unopened__"; a saved sort under "__noFolder__" is read as the Unopened sort once (migrate in the library's sort settings or read the old key as a fallback; say which); a saved window category "No Folder" decodes as Unopened. Tests: coding of the category, the sort key carry-over.
2. **What it lists.** Books from every folder whose `lastOpened` is nil, sorted by the category's sort; opening a book removes it from the list at the next derivation (the list cache's revision rules in LibraryListCache apply: check that `lastOpened` is a list field, `hasSameListFields(as:)`). The Feeds section at Unopened lists every feed with unplayed items (the feed rows keep their counts wording), and no feed without. The old No Folder contents (books at the root) are reachable in Folders at the root, so nothing is lost; say so in the report. Tests: a model with opened and unopened books across folders; feeds with and without unplayed items; a book opened leaves the list.
3. **VoiceOver and wording.** The picker's segment reads "Unopened"; any wording that said "No Folder" (search `No Folder` in the sources, not the documents) says the right thing; `LibrarySortState.swift`'s comments too. Pin the segment's label with a static constant and a test that needs no window.
4. **Continue Listening and other category-aware code** (`continueListeningButton`, breadcrumbs, Edit Mode, drag reordering, the "Move Book Up/Down" commands) behave at Unopened as they do at All Items (no manual order there). Tests where behavior could differ.

## Verify or report as unverified
- Live VoiceOver on the segmented picker is unverified; say so.
