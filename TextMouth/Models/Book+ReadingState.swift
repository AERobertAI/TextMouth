import Foundation

// MARK: - The Listener's Reading State, Weighed Between Two Copies

extension Book {
    /// What the listener's own use of a book leaves in its library row and
    /// in its record (bookInfo.json), apart from the book's details: where
    /// they are in it, when they last opened and played it, their
    /// bookmarks, the headings they skip, and the book's own settings
    /// (`hasOwnSettings`: voice, speed, pitch, what happens at its end, and
    /// the units of a skip). Two copies of a book can hold it apart: the row
    /// this Mac holds, and the record another Mac sharing the library in the
    /// cloud wrote since (risk 2 of LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md).
    /// `readingState(standingAgainst:)` weighs them.
    ///
    /// A view of fields `Book` keeps, not a field of its own, so it adds
    /// nothing to library.json or a record.
    struct ReadingState: Equatable, Sendable {
        var readingPosition: ReadingPosition?
        var lastOpened: Date?
        var lastPlaybackStarted: Date?
        var lastPlaybackStopped: Date?
        var bookmarks: [Bookmark]
        var skippedHeadingIDs: [String]?
        var skippedHeadings: [SkippedHeading]?
        var waitingSkippedHeadings: [SkippedHeading]?
        var localVoiceID: String?
        var localWPM: Double?
        var localPitch: Double?
        var localEndOfBookBehavior: String?
        var localSkipForwardUnit: String?
        var localSkipBackwardUnit: String?

        /// The reading state `record` keeps, read through the book it
        /// describes (`Book(record:filePath:folderPath:tmbDirectoryName:)`),
        /// so a record's fields are mapped in one place.
        init(record: BookInfo) {
            self = Book(record: record, filePath: "", folderPath: "", tmbDirectoryName: "").readingState
        }

        /// Each field given, as `Book.readingState` reads them.
        init(
            readingPosition: ReadingPosition?,
            lastOpened: Date?,
            lastPlaybackStarted: Date?,
            lastPlaybackStopped: Date?,
            bookmarks: [Bookmark],
            skippedHeadingIDs: [String]?,
            skippedHeadings: [SkippedHeading]?,
            waitingSkippedHeadings: [SkippedHeading]?,
            localVoiceID: String?,
            localWPM: Double?,
            localPitch: Double?,
            localEndOfBookBehavior: String?,
            localSkipForwardUnit: String?,
            localSkipBackwardUnit: String?
        ) {
            self.readingPosition = readingPosition
            self.lastOpened = lastOpened
            self.lastPlaybackStarted = lastPlaybackStarted
            self.lastPlaybackStopped = lastPlaybackStopped
            self.bookmarks = bookmarks
            self.skippedHeadingIDs = skippedHeadingIDs
            self.skippedHeadings = skippedHeadings
            self.waitingSkippedHeadings = waitingSkippedHeadings
            self.localVoiceID = localVoiceID
            self.localWPM = localWPM
            self.localPitch = localPitch
            self.localEndOfBookBehavior = localEndOfBookBehavior
            self.localSkipForwardUnit = localSkipForwardUnit
            self.localSkipBackwardUnit = localSkipBackwardUnit
        }
    }

    /// The reading state that stands between this book's and `recorded`,
    /// the one its record holds: the one rule by which a library row and
    /// its record are weighed, at every write of the record
    /// (`bookInfo(replacing:contentIndex:revisionFloor:...)`) and when a
    /// reader opens the book (`ReaderViewModel.takeNewerRecordedState(_:)`).
    /// It follows section 5 of LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md,
    /// the rules a later merge of two devices will keep, as far as today's
    /// records carry a clock:
    ///
    /// - The place: the later by its date (`ReadingPosition.lastUpdated`),
    ///   compared to the second, as both files keep it, so two copies of
    ///   one save tie, and a tie keeps this book's. The later place wins
    ///   even when it is earlier in the book, since going back to reread a
    ///   chapter is a later place, and a place beats none. A place saved
    ///   without moving keeps its date (`ReaderViewModel.savePosition()`),
    ///   so opening a book never makes an old place the later one.
    /// - Everything else here has no clock of its own in today's files: a
    ///   bookmark keeps only the date it was made, and the skipped headings
    ///   and the book's settings keep none. So they go with the later place,
    ///   as one, the skipped headings' three lists together: the copy whose
    ///   place is later was written by whoever read the book last, and holds
    ///   them as that reader left them. A union of the two copies' bookmarks
    ///   would bring back every bookmark deleted where the book was read
    ///   last, since nothing marks a deletion yet (section 5 keeps one, a
    ///   tombstone, in Phase 2). A change made on a Mac whose place is the
    ///   earlier, and not moved since, gives way to the other Mac's.
    /// - The playback times go with the later place as a pair; the date the
    ///   book was last opened is the later of the two, since an opening
    ///   without a move dates the opening and not the place.
    ///
    /// On one Mac the record is written from the row, so its place is never
    /// the later and this book's state stands, exactly as before. Returns
    /// this book's state when it stands.
    func readingState(standingAgainst recorded: ReadingState) -> ReadingState {
        let own = readingState
        guard let recordedPosition = recorded.readingPosition,
              recordedPosition.isSavedLater(than: own.readingPosition) else { return own }
        var standing = recorded
        standing.lastOpened = [own.lastOpened, recorded.lastOpened].compactMap { $0 }.max()
        return standing
    }

    /// Takes the reading state that stands between this book's and the one
    /// `record` holds (`readingState(standingAgainst:)`), when `record` is
    /// this book's own; another book's record, as an old shared package may
    /// hold, changes nothing. Returns whether anything changed.
    @discardableResult
    mutating func takeStandingReadingState(of record: BookInfo) -> Bool {
        guard record.metadata.bookID == id else { return false }
        let standing = readingState(standingAgainst: ReadingState(record: record))
        guard standing != readingState else { return false }
        readingState = standing
        return true
    }
}

// MARK: - Which Place Was Saved Later

extension ReadingPosition {
    /// Whether this place was saved later than `other`, to the second, as
    /// library.json and bookInfo.json keep a place's date (ISO 8601 drops
    /// the fraction), so the two copies of one save are never later than
    /// each other, whichever was read back from a file. A place is later
    /// than none.
    func isSavedLater(than other: ReadingPosition?) -> Bool {
        guard let other else { return true }
        return Self.storedSecond(of: lastUpdated) > Self.storedSecond(of: other.lastUpdated)
    }

    /// `date` as the files keep it: in whole seconds.
    private static func storedSecond(of date: Date) -> TimeInterval {
        date.timeIntervalSince1970.rounded(.down)
    }
}
