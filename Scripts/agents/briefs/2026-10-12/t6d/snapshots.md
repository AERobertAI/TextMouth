# t6d task "snapshots": the old text, copied aside with the book's places, and the move from it

Slug `t6d-snapshots`, branch `t6d/snapshots`, board task in your launch prompt. Read `worker-common.md` beside this file first. One commit, or two (the store, then the move).

## Background
When TextMouth rebuilds a book's text, a later task's `MarkdownCacheService.writeCache(for:)` will, just before it replaces content.md, copy the old content.md aside with the book's places as they are (a **snapshot**), then write the new text, then move the places from the snapshot's text to the new one. The moved places are committed to the book's record with its analysis, and the snapshot is deleted once the record holds them. A snapshot left by a crash or a quit between the write and the commit is finished at the next launch. This task builds the snapshot store and the move; it calls nothing in the app yet.

The design (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9): the copy is kept in a folder of this Mac's own, beside Working Copies, never in the data directory, which a cloud library would upload. With the library on the startup disk the copy is a clone, taking no space until one of the two files changes (`FileManager.copyItem(at:to:)` clones on APFS when source and destination share a volume); elsewhere it is an ordinary copy (0.67 MB for a typical book). The debug log gets one line a book when anything moved, counts only (`PlaceRelocator.Counts.logLine(title:)`).

## Read (by line range)
- `TextMouth/Models/CloudStorageContract.swift`, lines 566-634: `MachineLocalPaths`.
- `TextMouth/Services/MarkdownCacheService.swift`: `cacheText(from:at:)`, lines 326-337; `parseMultiChapterMarkdown(_:bookTitle:bookAuthor:contentIndex:)`, lines 394-449.
- `TextMouth/Models/PlaceRelocator.swift`: `Places` (now `Codable`, with `waitingSkippedHeadings`), `Outcome`, `Counts` and `logLine(title:)`, and the static `relocate(_:from:to:movedAt:)` (search for `from old:`), which reads the old text only when some place moved.
- `TextMouth/Services/DiagnosticLog.swift`, lines 60-80 and 127-135: `DiagnosticLog.event(.storage, line)` writes one debug-log line.
- `TextMouth/Services/ArchiveExtraction.swift`, lines 355-460: how another of this Mac's folders (`MachineLocalPaths.archiveExtraction`) is made, listed, and swept of leftovers; follow its style.
- Tests: `TextMouthProductionTests/PlaceRelocatorTestSupport.swift` (`MillBook`, `SavedPlace`, `Phrase`); `CloudMaintenanceTestSupport.swift` lines 150-162 (`logLineCount(_:)`, `debugLogLines(containing:)`).

## What to build
1. **`MachineLocalPaths.placeSnapshots`**, after `workingCopies`: `root.appendingPathComponent("Place Snapshots", isDirectory: true)`. Doc: books' old text, each copied aside with the book's saved places as they were while a rebuild of its text moves them to the new text (T06's branch D); this Mac's own, never in the data directory, which a cloud library would upload.
2. **A new file, `TextMouth/Services/PlaceSnapshots.swift`**, holding two types.
3. **`struct PlaceSnapshot: Equatable, Sendable`**, one snapshot on disk:
   - `let folder: URL`: its own folder in the snapshots folder, named `"<book ID> <UUID>"`, so two rebuilds of one book never share one.
   - `let record: Record`, with `struct Record: Codable, Equatable, Sendable { bookID: UUID; title: String; author: String; places: PlaceRelocator.Places; takenAt: Date }`: the book, its title and author (the old text is read with them, as the reader reads a content.md; the title also names the book in the log line), its places as they were, and when the copy was made.
   - `static func keep(textAt cacheURL: URL, record: Record, in folder: URL = MachineLocalPaths.placeSnapshots) throws -> PlaceSnapshot`: creates the folders as needed; copies the file at `cacheURL` into the new folder as `content.md` with `FileManager.default.copyItem(at:to:)`; then writes the record as `places.json` (`JSONEncoder`, `.atomic`). The record is written last, so a folder without it was never finished. A failure removes the new folder before it throws.
   - `static func leftovers(in folder: URL = MachineLocalPaths.placeSnapshots) -> [PlaceSnapshot]`: every finished snapshot in `folder`, oldest first by `record.takenAt` (ties by folder name); a folder whose record is missing or cannot be read, or whose `content.md` is missing, is removed, being a copy a stop left unfinished; a missing `folder` is no snapshots. Files that are not folders are left alone.
   - `func oldText() throws -> DocumentContent`: the snapshot's `content.md` as this build reads a content.md: `MarkdownCacheService.cacheText(from:at:)` on its bytes, then `MarkdownCacheService.parseMultiChapterMarkdown(_, bookTitle: record.title, bookAuthor: record.author)`.
   - `func discard()`: removes the folder; a folder already gone is no error.
   - `func movePlaces(to new: DocumentContent, at date: Date) -> MovedPlaces?`: the move, in this order:
     1. `let outcome = try PlaceRelocator.relocate(record.places, from: { try oldText() }, to: new, movedAt: date)`. If reading the old text throws, the copy is no use: `discard()`, log one line, `PLACES_NOT_MOVED: <title>: <reason>` (`.storage`), and return nil.
     2. When `outcome.counts.anythingMoved`, log `outcome.counts.logLine(title: record.title)` (`.storage`).
     3. When `outcome.places == record.places`, nothing needs writing: `discard()` and return nil.
     4. Otherwise return `MovedPlaces(bookID: record.bookID, original: record.places, moved: outcome.places, snapshot: self)`, keeping the copy until the record holds the moved places.
     Whether to write is decided by comparing the places, never by the counts: `anythingMoved` is false when only a position's offset in the whole book or a place's words changed, which must still be written.
4. **`struct MovedPlaces: Equatable, Sendable`**: a book's places moved by a rebuild of its text: `bookID`, `original` (the places as they were when the old text was copied aside), `moved` (where they are in the new text), and `snapshot: PlaceSnapshot?` (the copy, deleted once the book's record holds the moved places; nil when there is none). `func discardSnapshot()` calls the snapshot's `discard()`. Its doc says that a writer takes each moved place only where the book still holds it as it was (`Book.takeMovedPlaces(original:moved:)`, another task's), so a place saved meanwhile wins.
5. Every function and type documented; the folder name, `content.md`, and `places.json` named once, as constants.

## Tests: a new class `PlaceSnapshotTests` (new file; run xcodegen and commit the project with it)
Store tests use a temporary folder of their own (`FileManager.default.temporaryDirectory` plus a UUID, removed in a teardown block), never `MachineLocalPaths`.
- **Keep and list.** `keep` makes a folder holding `content.md` with the source file's exact bytes and `places.json`; `leftovers` lists it with its record (equal to the one kept, places with a position, a bookmark, a skip, and a waiting skip); `discard()` removes it; `leftovers` is then empty.
- **Unfinished copies.** Beside a finished snapshot, a folder with only `content.md`, and one whose `places.json` holds `not json`, are removed by `leftovers`, which lists only the finished one; a stray file in the folder is left alone.
- **Two of one book.** Two snapshots of one book, kept a second apart (pass `takenAt` dates), are both listed, oldest first, in distinct folders.
- **The default folder** is inside `MachineLocalPaths.root` (which hosted tests keep in their sandbox): assert the path relation only; write nothing there.
- **The move.** Write a content.md made from `MillBook.chapters` (chapter markers: build it as `MarkdownCacheService.chapterMarker(title:)` lines and chapter texts, or take the bytes a `parseMultiChapterMarkdown` round trip accepts; check `splitChapters` lines 476-512 for the marker form) and keep it with a bookmark in chapter III (anchor from the parsed old text, `DocumentContent.anchor(at:measuredIn:)`). For a new text with a sentence put in before the bookmark, `movePlaces` returns `MovedPlaces` whose moved bookmark is at the same words in the new text (find them with `Phrase`), `original` equal to the record's places, and the snapshot still on disk; `discardSnapshot()` then removes it. The log holds one `PLACES_RELOCATED: <a unique title>:` line (`logLineCount`).
- **Nothing to write.** For a new text equal to the old, with places that have their words, `movePlaces` returns nil, the snapshot's folder is gone, and no `PLACES_RELOCATED` line names the title.
- **A copy that cannot be read.** With the snapshot's `content.md` deleted before the move, `movePlaces` returns nil, the folder is gone, and one `PLACES_NOT_MOVED: <title>:` line is logged.

## Run
`PlaceSnapshotTests`, `PlaceRelocatorBookTests`.

## Do not touch
`PlaceRelocator.swift`, `MarkdownCacheService.swift`, `Book.swift`, and any file but `CloudStorageContract.swift`, the new source and test files, and the project file.
