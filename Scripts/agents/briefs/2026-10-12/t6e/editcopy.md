# t6e-editcopy: an Edit Text session keeps a copy of the text its edits replace

- **Slug** `t6e-editcopy`; **branch** `t6e/editcopy`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are main's at 056e8a90. Earlier tasks of this team changed other regions of `PlaceSnapshots.swift` (the end of the file); find functions by name.

## What and why
Each edit Edit Text takes will move the book's places (reading position, bookmarks, skipped headings) from the text the edit replaced to the edited text, by branch D's diff. A later task does the move. This task keeps the old text it needs, as branch D's `PlaceSnapshot` keeps a rebuild's.
- **When a session begins,** content.md is copied aside as the session's old text.
- **At each edit taken,** the copy becomes the edited text: exactly the bytes taken, for the next take.
- **At a rebuild during the session,** the copy becomes the rebuilt text.
- **When the session ends,** the copy is deleted.
- **When TextMouth quits during a session,** the copy stays. A later task finishes it at launch.

In this task nothing moves yet: no place changes, and nothing is spoken or shown.

## Changes
1. **`TextMouth/Models/CloudStorageContract.swift` (lines 600-608):** add `MachineLocalPaths.editTextSnapshots`, `root` + "Edit Text Snapshots". Its doc says:
   - it holds the text of each book being edited with Edit Text, as TextMouth last took or wrote it, kept with the book's places, from which each edit taken moves them (T06's branch E, `PlaceSnapshot`);
   - it is this Mac's own, never in the data directory;
   - it is apart from `placeSnapshots`, whose launch recovery finishes rebuilds' leftovers and removes any folder there it cannot read.

   **Never nest one folder in the other.**
2. **`TextMouth/Services/PlaceSnapshots.swift`:**
   - `keep(textAt:record:in:)` (72-104) and a new `keep(text: Data, record:in:)` share one private function. It makes the folder, marks it in use first, puts the text (the file copied, which clones on APFS, or the bytes written atomically), writes the record last, and on failure removes the folder and unmarks it before it rethrows. **No second copy of that sequence.**
   - Add `func textBytes() throws -> Data` (reads the kept text); `oldText()` (154-161) reads through it.
3. **`TextMouth/Services/BookTextEditing.swift`:**
   - **`BookTextEdit` (54-68).** Add two fields with defaults, so `BookTextEdit(committed:text:)` still builds:
     - `var movedPlaces: MovedPlaces? = nil`: the book's places this edit moved, as its record took them. A later task fills it; here it stays nil.
     - `var textAside: PlaceSnapshot? = nil`: the edited text kept aside for the session's next take.
   - **`Session` (172-187).** Add `var oldText: PlaceSnapshot? = nil`: the book's text as TextMouth last took or wrote it, kept aside in `editTextSnapshots`; nil before it is kept, for an audiobook, and when none could be kept.
   - **`begin(_:_:)` (226-228).** A session started again over one that holds a copy discards that copy, unless it is the same.
   - **`end(_:)` (231-233)** discards the ended session's copy.
   - **New `func keepOldText(of book: Book)`.**
     - It runs on `queue`, asynchronously, inside `boundary.perform(.contentAnalysis)`, with the book `boundary.rebasedToCurrent(book)`.
     - It keeps nothing for an audiobook, a book without a package, a content.md that is missing or only in the cloud (`access.isInCloud`), or a session that already has a copy.
     - Otherwise it calls `PlaceSnapshot.keep(textAt: MarkdownCacheService.cacheURL(for:), record: Record(bookID:title:author:places: book.relocatablePlaces, takenAt: Date()), in: MachineLocalPaths.editTextSnapshots)`. The result goes on the session; if the session has ended meanwhile, the copy is discarded.
     - A failure keeps none, with one debug-log line in the form branch D's failed keep uses (`PLACES_NOT_KEPT`; find it in `MarkdownCacheService.swift`'s `writeCache`).
     - It runs before any check of the session, which runs on the same serial queue.
   - **Static `check(_:against:access:readingTexts:)` (580-681).**
     - Add the parameter `keepingTextAside: Bool = false`.
     - In the text book's adopt path, once the commit has succeeded (about 672-680), when `keepingTextAside`, keep the bytes the check took (`bytes`, never content.md read again, which may hold a newer save) with `keep(text:record:in:)`. The record holds `committed.relocatablePlaces`. A failure keeps none, with the same line.
     - Return the copy as `BookTextEdit.textAside`.
     - Transcript edits keep nothing.
   - **Instance `check(_:)` (298-329)** passes `keepingTextAside: true`. On `.adopted(let edit)`, it puts `edit.textAside` on the session in place of the previous copy, inside the lock, and discards the previous copy after the lock. When the session has ended meanwhile, it discards `edit.textAside`.
   - **`textRebuilt(_:writing:fingerprint:)` (395-415).** The session's copy becomes `bytes`, kept the same way and swapped the same way. Write one private helper for "put this copy on the session in place of the old one, discarding whichever is no longer used", and use it in `keepOldText`, `check(_:)`, and `textRebuilt`.
   - **`settleEditSavedWhileClosed`** keeps the default (no text aside).
4. **`TextMouth/Services/BookTextEditor.swift` `begin(_:baseline:)` (179-196):** once a session has started, `sessions.keepOldText(of:)` with `library?.bookByID(bookID)`, when there is one.

Every new function, field, and non-obvious block has its comment. Update `BookTextEditSessions`' type doc (147-166) with one sentence on the copy.

## Tests
**`PlaceSnapshotTests` (existing class):**
- `keep(text:record:in:)` writes exactly the bytes and the record;
- `textBytes()` reads them back;
- a keep that fails (a folder path that is a file) leaves no folder and nothing in use, for both forms.

**`BookTextEditTests`:** a new section `// MARK: - The Session's Copy of Its Old Text (T06's branch E)`, placed just before `// MARK: - Fixtures` (about line 723). Drive sessions as the tests there do (see `testAnEditIsTakenAsTheBooksText`, 127-183, and the file's test doubles):
- Beginning a session keeps one copy in `editTextSnapshots`, holding content.md's bytes and the book's places.
- An edit taken replaces it with exactly the bytes taken, and one copy of the book remains.
- A refused edit leaves the copy as it was.
- Ending the session deletes the copy.
- A rebuild during the session (`textRebuilt`) makes the copy the rebuilt bytes.
- A transcribed audiobook's session keeps no copy (see `TranscriptEditTests` for how one is made, and reuse its helpers if reachable).
- `PlaceSnapshot.leftovers()` of `placeSnapshots` never lists a session's copy.

Read a folder's contents directly in the tests, as `snapshotsHoldACopy(of:)` does (PlaceRelocationTestSupport.swift 151-155): `leftovers` skips copies in use.

**Run:** `PlaceSnapshotTests`, `BookTextEditTests`, `TranscriptEditTests`, `PlaceSnapshotRecoveryTests`, `PlaceRelocationAtRebuildTests`.

## Do not touch
- No move of places: the later task does it.
- `ReaderViewModel*.swift`, `LibraryViewModel*.swift`, `MarkdownCacheService.swift`, `LibraryPersistenceService.swift`, `PlaceRelocator.swift`, `PlaceRelocationTestSupport.swift`.
- `MovedPlaces` and its `taken(by:)` (the end of PlaceSnapshots.swift).
