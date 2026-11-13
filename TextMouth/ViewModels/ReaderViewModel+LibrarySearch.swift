import Foundation

// MARK: - Finding a Library Search's Match Again

/// Where a request from Search Library says to go, found again in the text
/// the reader shows: at the very place the search found it, or, when the
/// book's text changed since (Edit Text, a rebuild), at the match nearest
/// that place. Pure functions of the request and the book's text, so tests
/// can pin their choices without a reader.
enum LibrarySearchJumpPlace {
    /// The place the reader goes to.
    struct Found: Equatable {
        /// The content unit (chapter) holding the match.
        let chapterIndex: Int
        /// The match's UTF-16 offset in that chapter's text.
        let characterOffset: Int
        /// The heading or chapter title that names the place, if any.
        let locationTitle: String?
        /// Whether the match is not at the place the search found it, so
        /// the reader says the text changed.
        let isFoundAgain: Bool
    }

    // MARK: At the Place

    /// Whether the request's match is still at its place: the text of
    /// `chapterTexts` at the request's chapter and offset is a match for
    /// the request's query, with the request's options, and is the very
    /// text that matched. It costs one lookup at the place, whatever comes
    /// before it in the chapter, so it runs on the main actor:
    /// - A literal query is looked for in a window one character either
    ///   side of the match.
    /// - A regular expression is tried once, anchored at the place
    ///   (`BookTextSearch.Matcher.regexMatch(at:in:)`), with the chapter's
    ///   text around it in view, so look-behind, word boundaries, and
    ///   anchors read it as a search from the chapter's start does; the
    ///   expression is never run over the text before the place.
    ///
    /// The check never accepts text that is not a match there. It may say
    /// "no" for a match that is there, and the caller then searches the
    /// whole book off the main actor: for a literal query, when an
    /// overlapping match began a character earlier.
    static func holds(for request: LibrarySearchJumpRequest, in chapterTexts: [String]) -> Bool {
        guard chapterTexts.indices.contains(request.chapterIndex),
              request.characterOffset >= 0,
              let matcher = try? BookTextSearch.Matcher(query: request.query, options: request.options)
        else { return false }
        let chapterText = chapterTexts[request.chapterIndex] as NSString
        let chapterLength = chapterText.length
        let matchedLength = (request.matchedText as NSString).length
        guard matchedLength > 0, request.characterOffset + matchedLength <= chapterLength else { return false }

        // Whether a range found is the very match: at the place, with the
        // text that matched.
        func isTheMatch(_ range: NSRange) -> Bool {
            range.location == request.characterOffset && chapterText.substring(with: range) == request.matchedText
        }

        guard matcher.isLiteral else {
            return matcher.regexMatch(at: request.characterOffset, in: chapterTexts[request.chapterIndex])
                .map(isTheMatch) ?? false
        }
        var found = false
        // One character either side, kept within the chapter. The search
        // stops once it finds the place, or once it is past it (matches
        // come in reading order).
        let start = max(0, request.characterOffset - 1)
        let end = min(chapterLength, request.characterOffset + matchedLength + 1)
        matcher.enumerateLiteralRanges(in: chapterText, within: NSRange(location: start, length: end - start)) { range in
            if range.location == request.characterOffset {
                found = isTheMatch(range)
                return false
            }
            return range.location < request.characterOffset
        }
        return found
    }

    /// The place the request names, when its match is still there, named
    /// by the heading or chapter title of `corpus`; nil when it is not.
    static func atPlace(for request: LibrarySearchJumpRequest, in corpus: BookSearchCorpus) -> Found? {
        guard holds(for: request, in: corpus.chapterTexts) else { return nil }
        let location = BookSearchView.locationTitles(
            of: [(chapterIndex: request.chapterIndex, characterOffset: request.characterOffset)],
            headings: corpus.headings,
            chapterTitles: corpus.chapterTitles,
            bookTitle: corpus.bookTitle
        ).first ?? nil
        return Found(
            chapterIndex: request.chapterIndex,
            characterOffset: request.characterOffset,
            locationTitle: location,
            isFoundAgain: false
        )
    }

    // MARK: Near the Place

    /// Choose the match to go to among `matches`, the matches of the
    /// request's query in the book now, in reading order, for a request
    /// whose match is no longer at its place: the match whose offset from
    /// the start of the book is nearest the request's (the earlier one when
    /// two are as near); nil when the book has no match.
    static func nearest(to request: LibrarySearchJumpRequest, among matches: [BookSearchResult]) -> Found? {
        // `min(by:)` keeps the first of equals, and the matches are in
        // reading order, so a tie goes to the earlier match.
        guard let nearest = matches.min(by: {
            abs($0.globalOffset - request.globalOffset) < abs($1.globalOffset - request.globalOffset)
        }) else { return nil }
        return Found(
            chapterIndex: nearest.chapterIndex,
            characterOffset: nearest.characterOffset,
            locationTitle: nearest.locationTitle,
            isFoundAgain: true
        )
    }
}

// MARK: - Moving to a Library Search's Match

extension ReaderViewModel {

    /// The most matches the search for a request's new place collects. Far
    /// above what any book holds for a query someone chose to open a match
    /// of, so the nearest match is chosen from all of them; the limit only
    /// keeps a query such as "e" in a huge book from collecting without end.
    static let libraryJumpMatchLimit = 100_000

    /// Move to the match Search Library asked this reader to open, if a
    /// request waits for its book, claiming it so it is used once.
    ///
    /// A closed reader claims nothing, and a reader still loading leaves the
    /// request waiting until loading ends (`claimLibrarySearchJump()` is
    /// called again there), since the text is not known before that. Then:
    /// - A book with no text to search (an audiobook without a transcript)
    ///   says so, as Search in Book does, and stays where it is.
    /// - Otherwise the place itself is checked first, on the main actor,
    ///   with one lookup there, a literal query's in the few characters
    ///   around it and a regular expression's as one attempt anchored there
    ///   (`LibrarySearchJumpPlace.holds(for:in:)`): when the text there is
    ///   still the match, as it nearly always is, the move is made at once,
    ///   however far into its chapter the match is.
    /// - Only when the place no longer holds the match (the text changed
    ///   since the search) is the whole book searched, off the main actor,
    ///   by the engine Search in Book and Search Library share; the reader
    ///   then moves to the nearest match and says the text changed, or says
    ///   the match is gone and stays where it is.
    ///
    /// The move saves the place for Go Back and follows Auto-play on
    /// navigate, as a pick from Search in Book does
    /// (`goToSearchResult(chapterIndex:characterOffset:inTranscript:)`), and
    /// VoiceOver hears where the reader moved to, or why it did not move,
    /// once the reader's window is in front (`afterReaderComesForward(_:)`).
    func claimLibrarySearchJump() {
        guard !hasClosed, !isLoading else { return }
        guard let request = libraryJumpRequests.consume(for: book.id) else { return }
        // A later claim supersedes a search for an earlier one still running,
        // which stops there and then.
        libraryJumpGeneration += 1
        cancelLibraryJumpSearch()

        guard let corpus = searchCorpus else {
            // There is no text to find the match in. The words the Search in
            // Book command speaks for an audiobook tell why and what to do.
            let hasTranscript = TranscribedBooks.shared.contains(book.id)
            afterReaderComesForward { reader in
                reader.announceNoTextToSearch(hasTranscript: hasTranscript)
            }
            return
        }

        if let found = LibrarySearchJumpPlace.atPlace(for: request, in: corpus) {
            moveToLibrarySearchMatch(found, isTranscript: corpus.timing != nil)
            return
        }
        searchForLibraryMatchNearby(request, in: corpus)
    }

    /// Search the whole book for `request`'s query off the main actor, and
    /// when the search ends, move to the match nearest the request's place,
    /// or say the match is gone. The move is made only if this reader is
    /// still open, still holds the same book, and has claimed no later
    /// request meanwhile; either of those cancels the search
    /// (`cancelLibraryJumpSearch()`).
    private func searchForLibraryMatchNearby(_ request: LibrarySearchJumpRequest, in corpus: BookSearchCorpus) {
        let generation = libraryJumpGeneration
        let bookID = book.id
        let search = Self.searchWholeBook(for: request, in: corpus, limit: Self.libraryJumpMatchLimit)
        libraryJumpSearch = search
        Task { [weak self] in
            let outcome = await search.value

            guard let self, !self.hasClosed, self.book.id == bookID,
                  self.libraryJumpGeneration == generation else { return }
            self.libraryJumpSearch = nil
            // An invalid pattern cannot be here (the search that found the
            // match compiled it), but if it were, no match can be found.
            guard case let .matches(matches, _)? = outcome,
                  let found = LibrarySearchJumpPlace.nearest(to: request, among: matches) else {
                self.afterReaderComesForward { reader in
                    reader.announceToVoiceOver(LibrarySearchWording.matchGone)
                }
                return
            }
            self.moveToLibrarySearchMatch(found, isTranscript: corpus.timing != nil)
        }
    }

    /// Starts the search of the whole of `corpus` for `request`'s query, for
    /// a request whose match is no longer at its place: detached, so it runs
    /// off the main actor on Sendable copies, and without Search in Book's
    /// 500-match limit (up to `limit`), so the nearest match is found
    /// wherever it falls. Cancelling the task stops the search at once, as
    /// Search in Book's does (before each chapter and inside each lookup), and
    /// its outcome is then nil, as for a pattern that does not compile.
    nonisolated static func searchWholeBook(
        for request: LibrarySearchJumpRequest,
        in corpus: BookSearchCorpus,
        limit: Int
    ) -> Task<BookSearchOutcome?, Never> {
        Task.detached(priority: .userInitiated) {
            try? BookSearchEngine.search(
                query: request.query,
                options: request.options,
                in: corpus,
                limit: limit,
                isCancelled: { Task.isCancelled }
            )
        }
    }

    /// Stops the search for a moved match that runs for an earlier request,
    /// if one does: when a later request is claimed, and when the reader
    /// closes, so no search runs on for a request or a reader that is gone.
    func cancelLibraryJumpSearch() {
        libraryJumpSearch?.cancel()
        libraryJumpSearch = nil
    }

    /// Move to `found` the way a Search in Book pick does, then say where
    /// the move went, once the reader's window is in front
    /// (`afterReaderComesForward(_:)`). A text book hears the match's place
    /// ("Moved to the match, Chapter 3."), or that the text changed and the
    /// nearest match was taken. A transcript's move has already made its
    /// words, with the time the audio moved to (`pendingJumpAnnouncement`),
    /// which no closing sheet is here to speak, so they are taken now, said
    /// with the rest, and forgotten; a transcript's match found again says
    /// so first. Nothing is said if Go Back has undone the move by then.
    private func moveToLibrarySearchMatch(_ found: LibrarySearchJumpPlace.Found, isTranscript: Bool) {
        goToSearchResult(
            chapterIndex: found.chapterIndex,
            characterOffset: found.characterOffset,
            inTranscript: isTranscript
        )

        // The words the transcript's move made, taken so they are spoken
        // here and never again by a sheet that closes later.
        let transcriptWords = isTranscript ? pendingJumpAnnouncement : nil
        pendingJumpAnnouncement = nil

        afterReaderComesForward { reader in
            // The move saved the place it left for Go Back; once Go Back has
            // returned there, the move is no longer where the reader is.
            guard reader.hasSavedPosition else { return }
            if found.isFoundAgain {
                reader.announceToVoiceOver(LibrarySearchWording.movedToMatchFoundAgain)
                // The time, after the note, not over it.
                if let transcriptWords {
                    reader.announceToVoiceOverAfterCurrentSpeech(transcriptWords)
                }
            } else if let transcriptWords {
                reader.announceToVoiceOver(transcriptWords)
            } else {
                reader.announceToVoiceOver(LibrarySearchWording.movedToMatch(location: found.locationTitle))
            }
        }
    }

    /// Runs `announce` with this reader once its window is in front for a
    /// Search Library request: a moment later
    /// (`VoiceOverAnnouncer.afterSheetDelay`, REV11 F6's wait for VoiceOver
    /// to settle after a sheet closes). The Search Library window asks for
    /// the move just before it brings the reader's window forward
    /// (`LibrarySearchModel.openInReader`), and a reader that opens with the
    /// request claims it as its window appears, so words said at once came
    /// while the window changed, and the change cut them off. Nothing is said
    /// once the reader has closed, or has claimed a later request, whose own
    /// words are the ones to say.
    private func afterReaderComesForward(_ announce: @escaping @MainActor (ReaderViewModel) -> Void) {
        let generation = libraryJumpGeneration
        VoiceOverAnnouncer.afterSheetCloses { [weak self] in
            guard let self, !self.hasClosed, self.libraryJumpGeneration == generation else { return }
            announce(self)
        }
    }
}
