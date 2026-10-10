import Foundation

// MARK: - Saved Places (T06)

/// How a reader treats the places its book was saved at (T06): where a
/// saved place opens once the book's text has loaded.
extension ReaderViewModel {

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
        let chapters = content.chapters
        guard let last = chapters.indices.last, saved.chapter >= 0 else {
            return TextPlace(chapter: 0, offset: 0)
        }
        guard saved.chapter <= last else {
            let total = content.totalCharacterCount
            let wasAtTheEnd = savedGlobalOffset.map { total > 0 && $0 >= total } ?? false
            return TextPlace(chapter: last, offset: wasAtTheEnd ? chapters[last].text.utf16Length : 0)
        }
        let length = chapters[saved.chapter].text.utf16Length
        return TextPlace(chapter: saved.chapter, offset: min(max(saved.offset, 0), length))
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
