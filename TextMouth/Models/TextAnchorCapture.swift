import Foundation

// MARK: - Capturing Saved Places' Words (T06's Branch B)

extension DocumentContent {
    /// The anchor of `place` in this text (T06): the words just before and
    /// after it in its chapter's reading text, its share of the whole book,
    /// and `measure`, the text it was measured in
    /// (`TextAnchor.measure(ofTextCachedBy:)`). Nil for a chapter this text
    /// lacks.
    ///
    /// An offset outside its chapter is quoted at the chapter's nearer edge
    /// (`TextAnchor.init(capturingAt:in:chapterStart:bookLength:measuredIn:)`),
    /// which is where the user's answer to T06's question 7 puts a place
    /// past its chapter's end; its share still counts the offset as given,
    /// so a place at or past the end of the last chapter marks the end of
    /// the book, as `Book.restsAtEnd` reads it finished.
    func anchor(at place: TextPlace, measuredIn measure: String?) -> TextAnchor? {
        guard chapters.indices.contains(place.chapter) else { return nil }
        return TextAnchor(
            capturingAt: place.offset,
            in: chapters[place.chapter].text,
            chapterStart: chapterStartOffset(place.chapter),
            bookLength: totalCharacterCount,
            measuredIn: measure
        )
    }
}

// MARK: - The Words of Places Saved Before Anchors

/// The words captured for a book's saved places that had none (T06): its
/// position's, its bookmarks', and its skipped headings', each with where
/// it was captured, so it is given only to a place still saved there
/// without words (`Book.adoptCapturedAnchors(_:)`).
///
/// The user decided on October 10, 2026 (T06, question 6) that places
/// saved before anchors take their words from each book's text as it reads
/// now: the text they were saved in is gone, so a place that has drifted
/// already cannot be put back, but from then on it stays with the words it
/// points at. A reader's load captures them, and so does a launch pass for
/// the books not opened (`LibraryViewModel.captureMissingTextAnchors`).
struct CapturedPlaceAnchors: Equatable, Sendable {
    /// An anchor and the place it was captured at.
    struct Placed: Equatable, Sendable {
        /// Where the anchor was captured: the place as it was saved.
        let place: TextPlace
        /// The words captured there.
        let anchor: TextAnchor
    }

    /// The reading position's words, when they were captured.
    var position: Placed?
    /// Each bookmark's words, by the bookmark's ID.
    var bookmarks: [UUID: Placed] = [:]
    /// Each skipped heading's words, by its heading ID, which names where
    /// the heading starts as well.
    var skippedHeadings: [String: TextAnchor] = [:]

    /// How many places' words this holds.
    var count: Int {
        (position == nil ? 0 : 1) + bookmarks.count + skippedHeadings.count
    }

    /// Whether this holds no words at all.
    var isEmpty: Bool {
        count == 0
    }

    /// The words of each of `book`'s saved places that keeps none, captured
    /// from `content`, its text as it reads now, measured in `measure`:
    ///
    /// - its reading position, unless `includingPosition` is false, as for
    ///   a reader's load, whose own save gives the position its words;
    /// - each bookmark, in its place, or at its chapter's nearer edge when
    ///   the place lies outside it (`DocumentContent.anchor(at:measuredIn:)`);
    /// - each skipped heading whose ID names a heading of `content`, at that
    ///   heading's start.
    ///
    /// A position or bookmark in a chapter `content` lacks keeps none, and
    /// so does a skipped heading whose ID names no heading now: it waits for
    /// its heading rather than take the words that stand where it was, which
    /// could make it skip another section. An audiobook's places count time
    /// in its recording and keep none (P08).
    static func capturing(
        missingFrom book: Book,
        in content: DocumentContent,
        measuredIn measure: String?,
        includingPosition: Bool = true
    ) -> CapturedPlaceAnchors {
        var captured = CapturedPlaceAnchors()
        guard !book.format.isAudio else { return captured }
        /// The words of `place` in `content`, with the place.
        func placed(_ place: TextPlace) -> Placed? {
            content.anchor(at: place, measuredIn: measure).map { Placed(place: place, anchor: $0) }
        }
        if includingPosition, let position = book.readingPosition, position.anchor == nil {
            captured.position = placed(TextPlace(chapter: position.chapterIndex, offset: position.characterOffset))
        }
        for bookmark in book.bookmarks where bookmark.anchor == nil {
            captured.bookmarks[bookmark.id] = placed(TextPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset))
        }
        let waiting = (book.skippedHeadings ?? []).filter { $0.anchor == nil }
        guard !waiting.isEmpty else { return captured }
        // The book's headings by ID, the first of any two alike.
        var headings: [String: Heading] = [:]
        for heading in content.allHeadings where headings[heading.id] == nil {
            headings[heading.id] = heading
        }
        for skipped in waiting {
            guard let heading = headings[skipped.id] else { continue }
            let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
            captured.skippedHeadings[skipped.id] = content.anchor(at: start, measuredIn: measure)
        }
        return captured
    }
}
