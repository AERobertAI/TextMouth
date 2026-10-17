# libpolish/movesheet: the Move to Folder sheet that VoiceOver sometimes finds empty

Worker slug `libpolish-movesheet`, branch `libpolish/movesheet` made from `team/libpolish`. Lead: `libpolish-lead`. Read `Scripts/agents/briefs/2026-10-17/teams-common.md`, "The worker's part", and follow it.

## What the user said (October 17)

"the "move to folder" dialog sometimes pops up empty according to VO and sometimes properly".

## What the lead found (do not repeat this work)

- **The logs.** The user's logs record nothing about the Move sheet. The debug log since October 4 holds event lines only (tracing is off), none about sheets; the older generation's VoiceOver focus traces (to October 3) never name it. So the logs cannot tell an empty presentation from a full one, and item 5 below adds a line.
- **The cause, reproduced.** `LibraryView.swift:585-605` presents the sheet as `.sheet(isPresented: $showMoveSheet) { if !booksToMove.isEmpty { MoveFolderSheet(books: booksToMove, …) } }`. The body reads `booksToMove` nowhere else. So when `moveToFolder(_:)` (:1506-1516) sets `booksToMove` and `showMoveSheet` together, SwiftUI builds the sheet from the `LibraryView` value captured at the body's last run, whose `booksToMove` is still empty. The `if` then leaves the sheet with nothing in it. The lead's throwaway probe (hosted off screen, `ViewBodyCounter` records inside the sheet's content closure) showed:
  - this exact pattern, opened from a closure called outside a view update, as a SwiftUI `Button` or a context-menu item calls its action: the first presentation's content saw **no items**; later ones saw the right ones;
  - the same opened through `.sheet(item:)`: the right item every time;
  - the real `LibraryView`, opened by posting `.moveToFolder` (Command-Shift-M or the menu): it worked only because `LibraryView`'s body happened to run again in the same update (`ViewBodyCounter "LibraryView.list"` went up by one) and refreshed the captured value. The edit bar's Move and the row's context menu "Move to Folder…" have no such luck. That explains "sometimes".
- **The same defect elsewhere.** Rename Folder… (`folderToRename` and `showRenameFolderSheet`, :787-802, set at :1232-1236) and Move Folder… (`folderToMove` and `showMoveFolderSheet`, :804-818, set at :1237-1240) use the same `isPresented` plus `if let` of a `@State` value, from context-menu buttons, so they can open empty too. The Delete Folder destination sheet (:860) reads `libraryViewModel.pendingDeleteFolder`, a live object, and is fine; leave it.
- **Sheets do not attach to an off-screen window.** `window.attachedSheet` stays nil, but SwiftUI still makes the sheet's window and evaluates its content, so `ViewBodyCounter` is how a test sees what the content built.

## The change (three small commits)

### Commit 1: present Move to Folder… by a request that carries its books

1. In `TextMouth/Views/Library/LibrarySheetViews.swift`, after `MoveFolderSheet` (ends at :694), add a `// MARK: - Move to Folder's Presentation` section holding:
   - `struct MoveToFolderRequest: Identifiable, Equatable`, with `let id = UUID()` and `let books: [Book]`. Model it on `MoveToLibraryRequest` in `TextMouth/Views/Feeds/MoveToLibrarySheet.swift:7-12`; read that file, but do not edit it.
   - `struct MoveToFolderSheetPresentation: ViewModifier`, modelled on `MoveToLibrarySheetPresentation` (same file, :54-86). It has `@Binding var request: MoveToFolderRequest?`, `let library: LibraryViewModel`, `let onMove: @MainActor (MoveToFolderRequest, String) async -> OperationOutcome`, and `let onDismiss: () -> Void`. Its body is `content.sheet(item: $request, onDismiss: onDismiss) { request in MoveFolderSheet(books: request.books, library: library.library, lastMovedFolderPath: library.lastMovedFolderPath, onMove: { path in await onMove(request, path) }, onCreateFolder: { library.createFolderReturningOutcome(name: $0, parentPath: $1) }, onCancel: { self.request = nil }) }`. The sheet's content then comes only from the request it is handed, never from the owner's captured state.
2. In `MoveFolderSheet.body` (:621), put `let _ = ViewBodyCounter.record("MoveFolderSheet")` on its first line, as `BookRow` does (`LibrarySubviews.swift:458`). Debug builds count it; release builds compile it to nothing.
3. In `LibraryView.swift`:
   - Replace `booksToMove` and `showMoveSheet` (:236-237) with `@State private var moveRequest: MoveToFolderRequest?`, with a doc comment saying why: a request the sheet is handed, so it never opens empty.
   - Replace the `.sheet` at :583-605 with `.modifier(MoveToFolderSheetPresentation(…))`. Its `onMove` does what today's does with the request's books: `moveBooksReturningOutcome(request.books, toFolder: path)`, then `closingOnSuccess` keeping `afterMoveSheet.keep(outcome.message)`, `clearAllSelections()`, and `moveRequest = nil`. Its `onDismiss` is `sayWhatTheMoveLeft`. Keep the two-line comment above it.
   - In `moveToFolder(_:)` (:1506-1516), set `moveRequest = MoveToFolderRequest(books: books)` in place of the two assignments. Keep its guards and doc comment, saying "request" where it says "sheet".
4. **Tests,** in a new file `TextMouthProductionTests/MoveFolderSheetPresentationTests.swift`, class `MoveFolderSheetPresentationTests`, `@MainActor`. Run `/opt/homebrew/bin/xcodegen generate` and commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with it.
   - **(a) The first presentation has its books.** A private owner view in the test file holds `@State var request: MoveToFolderRequest?` and applies `MoveToFolderSheetPresentation` to a `Text`. In `.onAppear`, it stores into a small `@MainActor` box class an `open` closure that sets `request`, and a `close` closure that sets it to nil (if `.onAppear` does not run off screen, assign them in `body` with `let _ = …`, as the lead's probe did). Host it with `hostOffscreen` (`ViewsAndWindowsTestSupport.swift:35`), settle, record `ViewBodyCounter.count(of: "MoveFolderSheet")`, then call `box.open` from the test, outside any view update, with one book, and settle about 0.5 s. The count must rise. Close, open again with two other books, and the count must rise again. Use a `LibraryViewModel` from `FeedTestWorld` (`FeedTestSupport.swift:439`, `try FeedTestWorld(self, label: …)`, `world.library`), as `LibraryInfoSpeakerTests.swift:644-672` does.
   - **(b) Without the fix, (a) fails.** Before writing the modifier with `.sheet(item:)`, write its body once the old way (`@State` books, `.sheet(isPresented:)`, and `if !books.isEmpty`), run test (a), and keep its failing result line for your report. Then write it with `.sheet(item:)`. Commit only the fixed form.
   - **(c) The Library window opens it for the selected book.** Host the real `LibraryView` as `LibraryInfoSpeakerTests.swift:644-672` does, with two books in the world's folder (`world.library.library.books.append(Book(title:author:format:filePath:md5Hash:folderPath:))`, `filePath: "/nonexistent/…"`) and one folder made with `createFolderReturningFolder`. First, with no row selected, post `.moveToFolder` with `["sourceWindow": hosted.window]` and settle: the `MoveFolderSheet` count must not rise. Do this before any sheet opens, since an open sheet's content is built again as the window settles. Then select the list's last row, a book (`descendants(of:as: NSTableView.self)`, `selectRowIndexes`, settle 0.3 s), post again, and settle: the count must rise.
   - **(d) The request.** Two requests for the same books are different requests (their ids differ), so a second Move opens a sheet of its own.

### Commit 2: present Rename Folder… and Move Folder… by their folder

5. In `LibraryView.swift`, present Rename Folder… with `.sheet(item: $folderToRename) { folder in … }` and Move Folder… with `.sheet(item: $folderToMove) { folder in … }` (`BookFolder` is `Identifiable`). Remove `showRenameFolderSheet` and `showMoveFolderSheet` (:242-244). Every close that set one to false now sets its folder to nil, `editFolder(folder, closing:)` included. In `folderMenu` (:1231-1240), set `renameFolderText` before `folderToRename`. Keep each sheet's comment, and add one sentence saying the sheet is handed its folder, so it never opens empty. No hosted test can open these sheets, since only context-menu buttons do; say so in your report, and let the completion check below stand for them.

### Commit 3: say in the debug log what the Move sheet shows as it appears

6. In `MoveFolderSheet`, add `nonisolated static func shownLine(command: String, places: Int, items: Int) -> String` that returns `"MOVE_SHEET_SHOWN: \(command) lists \(places) place(s) for \(items) item(s)"`. In the existing `.onAppear` (:686-692), write it once with `DiagnosticLog.event(.app, …)`. `command` is `"Move to Folder"` when `heading` is nil and `"Move to Library"` otherwise; `places` is `folderOptions.count`; `items` is `books.count`. Never a title or a path. Comment why: so a report of an empty sheet can be checked against the log.
7. Add `"MOVE_SHEET_SHOWN"` to `LogContentPolicyTests.eventTags` (`TextMouthProductionTests/LogContentPolicyTests.swift:265`). Add a test of `shownLine` to `MoveFolderSheetPresentationTests` pinning both commands' exact lines.

## Tests to run (only these; `python3 Scripts/test/run-area.py <classes>` with `BBS_AGENT=libpolish-movesheet`)

`MoveFolderSheetPresentationTests LibraryFolderPickerTests FeedUIAddFeedTests FeedMoveToLibraryCommandTests LibraryFeedMoveToFolderTests LibraryInfoSpeakerTests LibraryFolderSettingsTargetTests ViewsAndWindowsLibraryListTests LogContentPolicyTests UncheckedConcurrencyPolicyTests`

Log to `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/libpolish-movesheet-<n>.log` (`--log`). Before you report, run `make lint-tests LINT_BASE=team/libpolish` and `make lint-a11y LINT_BASE=team/libpolish`, and fix what they find.

## Completion check (must print nothing)

    grep -rn "showMoveSheet\|booksToMove\|showRenameFolderSheet\|showMoveFolderSheet" TextMouth TextMouthProductionTests

## Do not touch

`MoveToLibrarySheet.swift`, `LibrarySubviews.swift`, `KeyboardShortcut*.swift`, `ShortcutPressDispatcher.swift`, `ReadingListWording.swift`, any `*.md` file, and every part of `LibraryView.swift` outside the lines named above: the reading-list and shortcut comments are other tasks'. Other teams own `FileImportService.swift`, the parsers, `FeedDownloadManager.swift`, and `LibraryPersistenceService.swift`.
