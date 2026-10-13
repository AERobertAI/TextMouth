import Foundation

// MARK: - Saved Places (T06)

/// How a reader treats the places its book was saved at (T06): where a
/// saved place opens once the book's text has loaded, and the words around
/// each place it saves, its anchor, by which a later text of the book can
/// find the place again (`TextAnchorFinder`). Nothing here is spoken or
/// shown.
extension ReaderViewModel {

    // MARK: The Words Around a Saved Place

    /// The place a book opened at, with the anchor it was saved with
    /// (`openedPlaceAnchor`).
    struct OpenedPlaceAnchor: Equatable {
        /// Where the book opened: its saved place, in the text as loaded.
        let place: TextPlace
        /// The anchor that place was saved with.
        let anchor: TextAnchor
    }

    /// The anchor of `place` in the text this reader shows, as it reads
    /// now, measured in `textAnchorMeasure`. Nil for an audiobook, whose
    /// places count time in its recording (P08), before the text has
    /// loaded, and for a chapter the text lacks.
    func capturedAnchor(at place: TextPlace) -> TextAnchor? {
        guard !isAudioBook, let content else { return nil }
        return content.anchor(at: place, measuredIn: textAnchorMeasure)
    }

    /// The anchor a place this reader saves at `place` keeps: the one the
    /// place the book opened at was saved with, while the cursor has not
    /// left that place (`openedPlaceAnchor`), and otherwise the words
    /// around `place` as the text reads now.
    ///
    /// So a place saved again where it was, as every open, close, and
    /// pause without moving saves it, keeps the words it was saved with,
    /// even when the text has changed under it since. A later build can
    /// then find it by those words, where words captured at its old numbers
    /// in the changed text would hold it to whatever stands there now. Once
    /// the listener moves, a place is wherever they took it, and takes the
    /// words there.
    func anchorToSave(at place: TextPlace) -> TextAnchor? {
        if let opened = openedPlaceAnchor, opened.place == place {
            return opened.anchor
        }
        return capturedAnchor(at: place)
    }

    /// Lets go of the anchor of the place the book opened at once the
    /// cursor is anywhere else: called by the cursor's observers, so a
    /// return to the same numbers later, after the listener has heard the
    /// text there, takes the words there.
    func letGoOfOpenedPlaceAnchorIfLeft() {
        guard let opened = openedPlaceAnchor,
              opened.place != TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset) else { return }
        openedPlaceAnchor = nil
    }

    /// Notes the text just loaded as the one the places this reader saves
    /// take their words from (T06), once the saved place has been brought
    /// into it (`openingPlace(of:savedGlobalOffset:in:)`):
    ///
    /// - Its measure (`TextAnchor.measure(ofTextCachedBy:)`): the text cache
    ///   version the load vouches for, `cacheFormatVersion`, or, when it
    ///   vouches for none, as when a rebuild failed and the content.md
    ///   already there was read as it is, the version the book records for
    ///   that content.md; nil when neither is known.
    /// - The anchor of the place the book opened at, when the cursor is at
    ///   the place the book's row saved and that place has an anchor, which
    ///   saves made before the cursor moves keep (`anchorToSave(at:)`).
    func noteLoadedTextForAnchors(cacheFormatVersion: String?) {
        textAnchorMeasure = (cacheFormatVersion ?? book.cacheFormatVersion).map(TextAnchor.measure(ofTextCachedBy:))
        let cursor = TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset)
        let saved = libraryViewModel.bookByID(book.id)?.readingPosition ?? book.readingPosition
        if !isAudioBook, let saved, let anchor = saved.anchor,
           saved.chapterIndex == cursor.chapter, saved.characterOffset == cursor.offset {
            openedPlaceAnchor = OpenedPlaceAnchor(place: cursor, anchor: anchor)
        } else {
            openedPlaceAnchor = nil
        }
    }

    /// Gives the bookmarks and skipped headings this book saved without
    /// words theirs, from the text just loaded, as it reads now (T06,
    /// question 6; `CapturedPlaceAnchors.capturing(missingFrom:in:measuredIn:includingPosition:)`):
    /// the book's row and record through the library, and this reader's own
    /// copies. The position takes its words from the save the load makes.
    /// Places that have words keep them, and nothing is spoken or shown.
    func captureMissingAnchorsAtLoad() {
        guard !isAudioBook, let content, let row = libraryViewModel.bookByID(book.id) else { return }
        let captured = CapturedPlaceAnchors.capturing(
            missingFrom: row,
            in: content,
            measuredIn: textAnchorMeasure,
            includingPosition: false
        )
        guard !captured.isEmpty else { return }
        libraryViewModel.adoptCapturedAnchors([book.id: captured])
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        book.adoptCapturedAnchors(captured)
    }

    // MARK: Places Moved by a Rebuild of the Text

    /// Takes the places a rebuild of this book's text moved during its load
    /// (`movedPlaces`, already committed to the book's record by the load):
    /// into the library's row, this reader's own copy of the book, its
    /// bookmark list, and its cursor, before anything else reads its places.
    /// Nothing is spoken or shown. Does nothing for nil, or for an audiobook,
    /// whose places count time in its recording (P08).
    ///
    /// Each take is guarded as the record's was (`Book.takeMovedPlaces(original:moved:)`):
    /// a place only moves where it is still as it was, so one the listener
    /// saved meanwhile stays. The cursor follows the position only when it
    /// was at the place the book was saved at, and the reader's copy took the
    /// moved position, so a cursor the listener already moved is left alone.
    func takeMovedPlaces(_ movedPlaces: MovedPlaces?) {
        guard !isAudioBook, let movedPlaces else { return }
        let original = movedPlaces.original
        let moved = movedPlaces.moved

        // Whether the cursor is at the place the book was saved at, noted
        // before the copies change.
        let cursorWasAtSavedPlace = original.position.map {
            $0.chapterIndex == currentChapterIndex && $0.characterOffset == currentCharacterOffset
        } ?? false

        // The library's row, saved only when taking the places changes it.
        // A trial copy tells, so an unchanged row is not saved again.
        let row = libraryViewModel.bookByID(book.id)
        if var trial = row, trial.takeMovedPlaces(original: original, moved: moved) {
            libraryViewModel.updateBook(id: book.id) { _ = $0.takeMovedPlaces(original: original, moved: moved) }
        }

        // This reader's own copy, and the bookmark list it shows: the row's
        // as the library now holds it (as `captureMissingAnchorsAtLoad`
        // does), or the reader's own when the book has no row.
        book.takeMovedPlaces(original: original, moved: moved)
        bookmarks = row == nil ? book.bookmarks : libraryViewModel.bookmarksForBook(book.id)

        // The cursor, when it was at the saved place and that place moved.
        if cursorWasAtSavedPlace, let position = moved.position, book.readingPosition == position {
            currentChapterIndex = position.chapterIndex
            currentCharacterOffset = position.characterOffset
        }
    }

    // MARK: Where a Saved Place Opens

    /// Where a book saved at `saved` opens in `content`, its text as just
    /// loaded (T06's question 7, with TODO P07's end of a book). A place the
    /// text holds opens there; one it does not hold opens at the nearest
    /// place that keeps what the saved place meant:
    ///
    /// - An offset past its chapter's end opens at that end, which in the
    ///   last chapter is the book's end (`endOfBookPlace`), so a book saved
    ///   at its end opens finished even when its text has shortened there
    ///   since, as a new text extraction or an edit trimming the end can
    ///   leave it. The user decided on October 10, 2026 (T06, question 7)
    ///   that such a place goes to its chapter's end. It used to go to the
    ///   chapter's start, and be saved there, so a finished book stopped
    ///   reading Finished (board #2028).
    /// - An offset before its chapter's start opens at that start, and a
    ///   chapter before the first at the book's start.
    /// - A chapter past the book's last, as when chapters were merged or
    ///   removed since, opens at the book's end when the saved place was at
    ///   or past the book's end by `savedGlobalOffset`, its offset in the
    ///   whole book, as `Book.restsAtEnd` reads a finished book; otherwise
    ///   at the last chapter's start, as before.
    ///
    /// A place the text holds opens there whatever `savedGlobalOffset` says:
    /// the text before it may have shortened since it was saved, so only its
    /// chapter and offset say where it is now. A book without text opens at
    /// its start.
    nonisolated static func openingPlace(
        of saved: TextPlace,
        savedGlobalOffset: Int?,
        in content: DocumentContent
    ) -> TextPlace {
        // The one rule (`TextPlace.opening`), which the place relocator
        // follows too for a place saved without words.
        let chapters = content.chapters
        return saved.opening(
            savedGlobalOffset: savedGlobalOffset,
            chapterCount: chapters.count,
            bookLength: content.totalCharacterCount
        ) { chapters[$0].text.utf16Length }
    }

    /// The offset in the whole book of the place this reader opened its
    /// book at, as the book's row saved it (`Book.restsAtEnd` reads the same
    /// offset), while the cursor is still at `place`: nil when the cursor is
    /// elsewhere, or the book had no saved place.
    func savedGlobalOffset(of place: TextPlace) -> Int? {
        guard let position = book.readingPosition,
              position.chapterIndex == place.chapter,
              position.characterOffset == place.offset else { return nil }
        return position.globalCharacterOffset ?? position.characterOffset
    }
}
