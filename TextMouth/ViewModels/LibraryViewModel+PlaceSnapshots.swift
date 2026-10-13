import Foundation

// MARK: - Finishing the Moves a Stop Left Undone

extension LibraryViewModel {
    /// What a pass over the leftover copies of old texts did
    /// (`finishLeftoverPlaceMoves(access:then:)`).
    struct PlaceRecoveryOutcome: Sendable {
        /// The places moved and saved to their books' records, which the
        /// library rows take too.
        var moves: [MovedPlaces] = []
        /// Copies finished: their places moved and saved, or found to need
        /// no move.
        var finished = 0
        /// Copies left for a later launch: a book a reader has open or an
        /// Edit Text session holds, a file only in the cloud or unreadable,
        /// or a record that could not be written.
        var left = 0

        /// The debug log's line, `PLACES_RECOVERED: finished N, left M for a
        /// later launch`; counts only.
        var logLine: String {
            "PLACES_RECOVERED: finished \(finished), left \(left) for a later launch"
        }
    }

    /// What finishing one leftover copy came to.
    enum PlaceMoveResult: Sendable {
        /// Done: the places moved and saved (the moves to give the row), or
        /// none needed to move. The copy is gone.
        case finished(MovedPlaces?)
        /// Not done: the copy stays for a later launch.
        case left
        /// The copy was discarded because it could never be finished (the
        /// book has no package, or its record belongs to another book).
        case gone
    }

    /// Finishes the moves of places that a stop left undone (T06's branch D,
    /// TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9, step 6).
    ///
    /// A rebuild of a book's text that has places to move copies the old
    /// text aside with the places (`PlaceSnapshot`), writes the new text,
    /// moves the places, and commits them with the book's analysis, which
    /// deletes the copy. A crash or a quit between the write and the commit
    /// leaves the copy, while the book's record still holds its places at the
    /// old text's numbers and content.md holds the new text. This pass finds
    /// each copy, oldest first (`PlaceSnapshot.leftovers()`), moves the
    /// book's places from it against the content.md now there, saves them to
    /// the record (`LibraryPersistenceService.saveMovedPlaces(_:for:)`), and
    /// deletes the copy. It runs before any other launch pass reads a book's
    /// places or text: the anchor pass would otherwise give a place without
    /// words the words standing at its old numbers in the new text.
    ///
    /// Each copy is read off the main thread, one at a time, with dataless
    /// files left in the cloud:
    /// - A book no longer in the library: the copy is discarded.
    /// - A book a reader has open, or whose text an Edit Text session holds,
    ///   is left for a later launch, as is a book whose content.md or record
    ///   is only in the cloud, or whose content.md cannot be read.
    /// - Otherwise the places move and are saved, each only where the record
    ///   still holds it as it was, so a place saved since wins.
    ///
    /// The rows take the moved places on the main actor, in one change of the
    /// library and one save, each only where the row still holds the place as
    /// it was. Nothing is spoken or shown. When any copy was finished or
    /// left, one line, `PLACES_RECOVERED`, counts them; a copy discarded for
    /// a book no longer in the library counts in neither.
    ///
    /// - Parameters:
    ///   - access: How the pass reaches the books' files: `live` in the app;
    ///     tests pass one that pretends files are in the cloud.
    ///   - completion: Called on the main actor once the pass has ended.
    func finishLeftoverPlaceMoves(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let rows = Dictionary(library.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let open = openBookIDs
        DispatchQueue.global(qos: .utility).async {
            let outcome = Self.recoverLeftoverPlaceMoves(rows: rows, open: open, access: access)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.takeRecoveredPlaces(outcome.moves)
                if outcome.finished + outcome.left > 0 {
                    DiagnosticLog.event(.storage, outcome.logLine)
                }
                completion?()
            }
        }
    }

    /// Finishes every leftover copy that can be finished now, on the pass's
    /// thread, and reports what it did. `rows` are the library's books as
    /// the pass began, and `open` the books a reader has open.
    nonisolated static func recoverLeftoverPlaceMoves(
        rows: [UUID: Book],
        open: Set<UUID>,
        access: MaintenanceFileAccess
    ) -> PlaceRecoveryOutcome {
        let boundary = StorageBoundary.shared
        var outcome = PlaceRecoveryOutcome()
        for copy in PlaceSnapshot.leftovers() {
            guard let listed = rows[copy.record.bookID] else {
                // The book left the library: its places are gone with it.
                copy.discard()
                continue
            }
            // A reader gives a book its places as it loads, and an Edit Text
            // session may hold an edit of the text not taken yet.
            guard !open.contains(listed.id), !BookTextEditSessions.shared.isEditing(listed.id) else {
                outcome.left += 1
                continue
            }
            let result = autoreleasepool {
                boundary.perform(.contentAnalysis) { _ in
                    // The book as listed when the pass began, with its paths
                    // in the data directory in use now.
                    finishPlaceMove(from: copy, of: boundary.rebasedToCurrent(listed), access: access)
                }
            }
            releaseBatchParserMemory()
            switch result {
            case .finished(let moved):
                outcome.finished += 1
                if let moved {
                    outcome.moves.append(moved)
                }
            case .left:
                outcome.left += 1
            case .gone:
                break
            }
        }
        return outcome
    }

    /// Moves `book`'s places from the copy of its old text to the content.md
    /// now there and saves them to its record, as the launch pass does for
    /// each copy (`finishLeftoverPlaceMoves(access:then:)`). A content.md or
    /// record in the cloud, a text that cannot be read, or a record that
    /// cannot be written leaves the copy.
    nonisolated private static func finishPlaceMove(
        from copy: PlaceSnapshot,
        of book: Book,
        access: MaintenanceFileAccess
    ) -> PlaceMoveResult {
        let text: DocumentContent
        do {
            try access.requireOnThisMac(book, reading: [.textCache, .record])
            text = try access.read(MarkdownCacheService.cacheURL(for: book)) {
                try MarkdownCacheService.loadFromCache(for: book)
            }
        } catch {
            return .left
        }
        // Nothing to write when no place moved: the copy is gone.
        guard let moved = copy.movePlaces(to: text, at: Date()) else { return .finished(nil) }
        do {
            guard try LibraryPersistenceService.saveMovedPlaces(moved, for: book) != nil else {
                // The copy stays when the record is only in the cloud, and is
                // gone when it could never be finished.
                return FileManager.default.fileExists(atPath: copy.folder.path) ? .left : .gone
            }
            return .finished(moved)
        } catch {
            return .left
        }
    }

    /// Gives the rows the places the pass moved and saved, each only where
    /// the row still holds it as it was
    /// (`Book.takeMovedPlaces(original:moved:)`), in one change of the
    /// library and one save; when no row changed, nothing is saved.
    private func takeRecoveredPlaces(_ moves: [MovedPlaces]) {
        var books = library.books
        var changed = false
        for index in books.indices {
            for moved in moves where moved.bookID == books[index].id {
                if books[index].takeMovedPlaces(original: moved.original, moved: moved.moved) {
                    changed = true
                }
            }
        }
        guard changed else { return }
        library.books = books
        save()
    }
}
