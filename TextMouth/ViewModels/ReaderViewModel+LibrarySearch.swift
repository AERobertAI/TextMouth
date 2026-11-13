import Foundation

// MARK: - Finding a Library Search's Match Again

/// Where a request from Search Library says to go, found again in the text
/// the reader shows: at the very place the search found it, or, when the
/// book's text changed since (Edit Text, a rebuild), at the match nearest
/// that place. A pure function of the request and the book's current
/// matches, so tests can pin its choice without a reader.
enum LibrarySearchJumpPlace {
    /// The match the reader goes to.
    struct Found: Equatable {
        /// The match, as the book's text holds it now.
        let match: BookSearchResult
        /// Whether the match is not at the place the search found it, so
        /// the reader says the text changed.
        let isFoundAgain: Bool
    }

    /// Choose the match to go to among `matches`, the matches of the
    /// request's query in the book now, in reading order.
    ///
    /// - Returns: The match at the request's own chapter and offset whose
    ///   text is still the text that matched; otherwise the match whose
    ///   offset from the start of the book is nearest the request's (the
    ///   earlier one when two are as near); nil when the book has no match.
    static func choose(for request: LibrarySearchJumpRequest, among matches: [BookSearchResult]) -> Found? {
        // The text at the place is what the search found: nothing changed.
        if let exact = matches.first(where: {
            $0.chapterIndex == request.chapterIndex
                && $0.characterOffset == request.characterOffset
                && $0.matchedText == request.matchedText
        }) {
            return Found(match: exact, isFoundAgain: false)
        }
        // The text changed: take the nearest match. `min(by:)` keeps the
        // first of equals, and the matches are in reading order, so a tie
        // goes to the earlier match.
        guard let nearest = matches.min(by: {
            abs($0.globalOffset - request.globalOffset) < abs($1.globalOffset - request.globalOffset)
        }) else { return nil }
        return Found(match: nearest, isFoundAgain: true)
    }
}

// MARK: - Moving to a Library Search's Match

extension ReaderViewModel {

    /// The most matches the search for a request's place collects. Far above
    /// what any book holds for a query someone chose to open a match of, so
    /// the nearest match is chosen from all of them; the limit only keeps a
    /// query such as "e" in a huge book from collecting without end.
    static let libraryJumpMatchLimit = 100_000

    /// Move to the match Search Library asked this reader to open, if a
    /// request waits for its book, claiming it so it is used once.
    ///
    /// A closed reader claims nothing, and a reader still loading leaves the
    /// request waiting until loading ends (`claimLibrarySearchJump()` is
    /// called again there), since the text is not known before that. Then:
    /// - A book with no text to search (an audiobook without a transcript)
    ///   says so, as Search in Book does, and stays where it is.
    /// - Otherwise the request's query is searched for in the book with the
    ///   request's options, by the engine Search in Book and Search Library
    ///   share, and the request's match is found among the results
    ///   (`LibrarySearchJumpPlace`). The search runs here, on the main
    ///   actor, because it is one book searched once, as a person waits for
    ///   the window to open: its cost is measured by
    ///   `LibrarySearchJumpTests.testSearchingOneLargeBookForThePlaceIsFast`.
    /// - The move saves the place for Go Back and follows Auto-play on
    ///   navigate, as a pick from Search in Book does
    ///   (`goToSearchResult(chapterIndex:characterOffset:inTranscript:)`),
    ///   and VoiceOver hears where the reader moved to. A match that is no
    ///   longer in the text is said so, and the cursor stays.
    func claimLibrarySearchJump() {
        guard !hasClosed, !isLoading else { return }
        guard let request = libraryJumpRequests.consume(for: book.id) else { return }

        guard let corpus = searchCorpus else {
            // There is no text to find the match in. The words the Search in
            // Book command speaks for an audiobook tell why and what to do.
            announceNoTextToSearch(hasTranscript: TranscribedBooks.shared.contains(book.id))
            return
        }

        // Search the whole book for the request's query, as Search in Book
        // does but without its 500-match limit, so the match is found
        // wherever it falls.
        let outcome: BookSearchOutcome
        do {
            outcome = try BookSearchEngine.search(
                query: request.query,
                options: request.options,
                in: corpus,
                limit: Self.libraryJumpMatchLimit,
                isCancelled: { false }
            )
        } catch {
            // Never thrown, as the search cannot be cancelled; treated as a
            // match that cannot be found, the safe way to fail.
            announceToVoiceOver(LibrarySearchWording.matchGone)
            return
        }

        // An invalid pattern cannot be here (the search that found the match
        // compiled it), but if it were, no match can be found.
        guard case let .matches(matches, _) = outcome,
              let found = LibrarySearchJumpPlace.choose(for: request, among: matches) else {
            announceToVoiceOver(LibrarySearchWording.matchGone)
            return
        }

        let isTranscript = corpus.timing != nil
        goToSearchResult(
            chapterIndex: found.match.chapterIndex,
            characterOffset: found.match.characterOffset,
            inTranscript: isTranscript
        )
        announceLibrarySearchJump(to: found, isTranscript: isTranscript)
    }

    /// Say where the move to a library search's match went. A text book
    /// hears the match's place ("Moved to the match, Chapter 3."), or that
    /// the text changed and the nearest match was taken. A transcript's
    /// move has already made its words, with the time the audio moved to
    /// (`pendingJumpAnnouncement`), which no closing sheet is here to speak,
    /// so they are spoken now and forgotten; a transcript's match found
    /// again says so first.
    private func announceLibrarySearchJump(to found: LibrarySearchJumpPlace.Found, isTranscript: Bool) {
        // The words the transcript's move made, taken so they are spoken
        // here and never again by a sheet that closes later.
        let transcriptWords = isTranscript ? pendingJumpAnnouncement : nil
        pendingJumpAnnouncement = nil

        if found.isFoundAgain {
            announceToVoiceOver(LibrarySearchWording.movedToMatchFoundAgain)
            // The time, after the note, not over it.
            if let transcriptWords {
                announceToVoiceOverAfterCurrentSpeech(transcriptWords)
            }
        } else if let transcriptWords {
            announceToVoiceOver(transcriptWords)
        } else {
            announceToVoiceOver(LibrarySearchWording.movedToMatch(location: found.match.locationTitle))
        }
    }
}
