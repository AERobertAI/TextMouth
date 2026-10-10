import Foundation

// MARK: - The Words of Places Saved Before Anchors (T06)

/// How the library gives the places saved before anchors their words
/// (T06, question 6): a reader's load hands over what it captured from the
/// text it shows, a launch pass reads the books not opened, and the library
/// keeps the words in each book's row and record.
extension LibraryViewModel {

    // MARK: The Launch Pass

    /// What the launch pass that gives places saved before anchors their
    /// words did (`captureMissingTextAnchors(access:then:)`), counts only,
    /// for its one log line.
    struct TextAnchorBackfillOutcome: Equatable, Sendable {
        /// The books whose places took their words.
        var books = 0
        /// The reading positions that took their words.
        var positions = 0
        /// The bookmarks that took their words.
        var bookmarks = 0
        /// The skipped headings that took their words.
        var skippedHeadings = 0
        /// The books left for a later launch: their content.md only in the
        /// cloud, their text held by an Edit Text session, or the book open
        /// in a reader, which gives its places their words as it loads.
        var waiting = 0
        /// The places left without words: in a chapter their book's text
        /// lacks, a skipped heading whose ID names no heading now, or in a
        /// book whose content.md is missing or cannot be read.
        var unplaced = 0

        /// The debug log's line, counts only, as in "TEXT_ANCHORS_BACKFILLED:
        /// 3 books' places took their words: 3 positions, 1 bookmark, 0
        /// skipped headings; 1 book waits for a later launch; 2 places have
        /// no words to take".
        var logLine: String {
            "TEXT_ANCHORS_BACKFILLED: "
                + "\(CountWording.phrase(books, singular: "book's places", plural: "books' places")) took their words: "
                + "\(CountWording.phrase(positions, singular: "position", plural: "positions")), "
                + "\(CountWording.phrase(bookmarks, singular: "bookmark", plural: "bookmarks")), "
                + "\(CountWording.phrase(skippedHeadings, singular: "skipped heading", plural: "skipped headings")); "
                + "\(CountWording.phrase(waiting, singular: "book waits", plural: "books wait")) for a later launch; "
                + "\(CountWording.phrase(unplaced, singular: "place has", plural: "places have")) no words to take"
        }
    }

    /// What reading a book's text for its places' words found
    /// (`readTextForAnchors(of:access:)`).
    enum TextAnchorReading: Sendable {
        /// The words of the places that had none, as the text reads now.
        case captured(CapturedPlaceAnchors)
        /// Its content.md is only in the cloud, or an Edit Text session
        /// holds its text: it waits for a later launch.
        case waiting
        /// It has no content.md, or one that cannot be read: its places stay
        /// without words until a later launch or its next open.
        case unreadable
    }

    /// Gives every place saved before anchors its words from its book's
    /// text as it reads now (T06, question 6). This is the launch's pass for
    /// the books not opened: `updateContentCachesAndStatistics` runs it before
    /// the text cache batch, so no book's text is rebuilt before its places
    /// hold the words of the text they were saved in (question 9). A reader
    /// gives the places of the book it opens their words as it loads
    /// (`ReaderViewModel.captureMissingAnchorsAtLoad()`).
    ///
    /// Only the books with a place without words are read: a text book with
    /// a package whose position, a bookmark, or a skipped heading has no
    /// anchor (`Book.placesWithoutAnchors`). Once a launch has given them
    /// their words, later launches read none, unless an older TextMouth on
    /// another Mac writes rows without them again. A book whose places cannot
    /// all take words (a chapter its text lacks, a skipped heading naming no
    /// heading now) is read again at each launch, finding nothing new.
    ///
    /// Each book's content.md is read off the main thread, one book at a
    /// time, with dataless files left in the cloud, and parsed as the reader
    /// parses it; nothing is written and no text is rebuilt
    /// (`readTextForAnchors(of:access:)`). The words are given on the main
    /// actor, each only to a place still saved where it was read, in one
    /// change of the library (`adoptCapturedAnchors(_:skipping:)`). A book
    /// whose content.md is only in the cloud, whose text an Edit Text
    /// session holds, or that a reader has open waits for a later launch.
    /// One line, `TEXT_ANCHORS_BACKFILLED`, counts what was done, whenever a
    /// book had a place without words. Nothing is spoken or shown.
    ///
    /// - Parameters:
    ///   - access: How the pass reaches the books' files: `live` in the app;
    ///     tests pass one that pretends files are in the cloud.
    ///   - completion: Called on the main actor once the pass has ended,
    ///     with what it did.
    func captureMissingTextAnchors(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable (TextAnchorBackfillOutcome) -> Void)? = nil
    ) {
        let candidates = library.books.filter { !$0.tmbDirectoryName.isEmpty && $0.placesWithoutAnchors > 0 }
        guard !candidates.isEmpty else {
            completion?(TextAnchorBackfillOutcome())
            return
        }
        // A book a reader has open gives its places their words as it loads.
        let open = openBookIDs
        let readable = candidates.filter { !open.contains($0.id) }
        let openCount = candidates.count - readable.count
        DispatchQueue.global(qos: .utility).async {
            let boundary = StorageBoundary.shared
            var captures: [UUID: CapturedPlaceAnchors] = [:]
            var outcome = TextAnchorBackfillOutcome(waiting: openCount)
            for listed in readable {
                let reading = autoreleasepool {
                    boundary.perform(.contentAnalysis) { _ in
                        // The book as listed when the pass began, with its
                        // paths in the data directory in use now.
                        Self.readTextForAnchors(of: boundary.rebasedToCurrent(listed), access: access)
                    }
                }
                releaseBatchParserMemory()
                switch reading {
                case .captured(let captured):
                    captures[listed.id] = captured
                    outcome.unplaced += listed.placesWithoutAnchors - captured.count
                case .waiting:
                    outcome.waiting += 1
                case .unreadable:
                    outcome.unplaced += listed.placesWithoutAnchors
                }
            }
            let read = (captures: captures, outcome: outcome)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?(read.outcome)
                    return
                }
                let done = self.adoptBackfilledAnchors(read.captures, counted: read.outcome)
                DiagnosticLog.event(.storage, done.logLine)
                completion?(done)
            }
        }
    }

    /// Reads `book`'s text for the words of its places that have none, on
    /// the launch pass's thread (`captureMissingTextAnchors(access:then:)`):
    /// its content.md, read with dataless files left in the cloud and parsed
    /// as the reader parses it, measured in the text cache version the book
    /// records for that content.md (`TextAnchor.measure(ofTextCachedBy:)`),
    /// which is older than this build's for a book whose cache the batch
    /// then rebuilds. Nothing is written, and no text is rebuilt.
    nonisolated static func readTextForAnchors(of book: Book, access: MaintenanceFileAccess) -> TextAnchorReading {
        // A book whose text is being edited in the user's editor waits for
        // its session: its content.md may hold an edit not taken yet.
        guard !BookTextEditSessions.shared.isEditing(book.id) else { return .waiting }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        do {
            try access.requireOnThisMac(book, reading: .textCache)
            guard access.presence(of: cacheURL) == .present else { return .unreadable }
            let content = try access.read(cacheURL) { try MarkdownCacheService.loadFromCache(for: book) }
            // A content.md that went to the cloud while it was read may have
            // been read only in part.
            try access.requireOnThisMac(book, reading: .textCache)
            let measure = book.cacheFormatVersion.map(TextAnchor.measure(ofTextCachedBy:))
            return .captured(CapturedPlaceAnchors.capturing(missingFrom: book, in: content, measuredIn: measure))
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .waiting
        } catch {
            return .unreadable
        }
    }

    /// Gives the books' places the words the launch pass read (`captures`),
    /// and returns the pass's outcome, `read`, with what was given. A book a
    /// reader opened while the pass read waits for a later launch, since the
    /// reader gives its places their words as it loads.
    private func adoptBackfilledAnchors(
        _ captures: [UUID: CapturedPlaceAnchors],
        counted read: TextAnchorBackfillOutcome
    ) -> TextAnchorBackfillOutcome {
        var outcome = read
        let openedMeanwhile = Set(captures.keys).intersection(openBookIDs)
        outcome.waiting += openedMeanwhile.count
        let adopted = adoptCapturedAnchors(captures, skipping: openedMeanwhile)
        outcome.books = adopted.count
        for given in adopted.values {
            outcome.positions += given.position == nil ? 0 : 1
            outcome.bookmarks += given.bookmarks.count
            outcome.skippedHeadings += given.skippedHeadings.count
        }
        return outcome
    }

    // MARK: Giving Places Their Words

    /// Gives the places of each book `captures` names the words captured
    /// for them (`Book.adoptCapturedAnchors(_:)`), each only while the place
    /// is still saved where they were captured and has none, in one change
    /// of the library: library.json and each feed's index are saved once,
    /// and each book whose places took words has its record written. A book
    /// no longer in the library, or one `skipped` names, takes nothing.
    /// Neither a place's date nor a book's last-opened date changes: a place
    /// given its words has not moved, and its book was not opened.
    ///
    /// - Returns: The words given, by book; a book given none is left out.
    @discardableResult
    func adoptCapturedAnchors(
        _ captures: [UUID: CapturedPlaceAnchors],
        skipping skipped: Set<UUID> = []
    ) -> [UUID: CapturedPlaceAnchors] {
        var books = library.books
        var adopted: [UUID: CapturedPlaceAnchors] = [:]
        for index in books.indices {
            let id = books[index].id
            guard !skipped.contains(id), let captured = captures[id] else { continue }
            let given = books[index].adoptCapturedAnchors(captured)
            if !given.isEmpty {
                adopted[id] = given
            }
        }
        guard !adopted.isEmpty else { return adopted }
        library.books = books
        save()
        for book in books where adopted[book.id] != nil {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
        return adopted
    }
}
