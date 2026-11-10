import XCTest
@testable import TextMouth

/// Search in Book over a transcribed audiobook (T2): the search reads the
/// transcript's text, each result says when it is heard, and choosing one
/// moves the audio there, announced, with Go Back returning.
///
/// Books live in a library folder of the test's own; no reader speaks or
/// plays, and nothing reads the user's library or preferences.
@MainActor
final class TranscriptSearchTests: XCTestCase {

    // MARK: - Fixtures

    /// The reader of a silent two-track audiobook, not transcribed, loaded.
    private func untranscribedReader(_ label: String) async throws -> ReaderViewModel {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(
            title: "Plain Tracks \(UUID().uuidString.prefix(8))",
            trackDurations: [3, 2]
        )
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        return reader
    }

    /// The reader of a plain-text book, loaded.
    private func textBookReader(_ label: String) async throws -> ReaderViewModel {
        let world = try makeIntegrationWorld(label)
        let source = try makeSandboxDirectory("SearchSource").appendingPathComponent("Slip Notes.txt")
        try Data("Slip Notes\n\nThe ferry leaves the slip at first light.\n\nGulls follow it past the pier.\n".utf8)
            .write(to: source)
        let reader = world.openReader(for: try world.importBook(from: source))
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        return reader
    }

    /// The reader of a silent two-track audiobook (3 and 2 seconds) whose
    /// transcript is `TranscriptionUIScripts.twoTracks`, loaded.
    private func transcribedReader(_ label: String) async throws -> ReaderViewModel {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Notes \(UUID().uuidString.prefix(8))",
            trackDurations: [3, 2]
        )
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        return reader
    }

    /// The reader of a silent two-track audiobook (3 and 2 seconds) that was
    /// transcribed and whose second track was then replaced by a longer one,
    /// so its transcript no longer fits its audio: loaded, and showing no
    /// text. Also the text the transcript had, for a test to show again.
    private func staleTranscriptReader(_ label: String) async throws -> (reader: ReaderViewModel, text: TranscriptText) {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Notes \(UUID().uuidString.prefix(8))",
            trackDurations: [3, 2]
        )
        let installation = try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        try AudioTestFixtures.writeSilence(to: URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav"), duration: 4)
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        return (reader, installation.text)
    }

    // MARK: - Timing

    /// Chapters begin where the lengths of those before them add up: a
    /// chapter's spacing text counts ten characters a second.
    func testChaptersBeginWhereTheOnesBeforeThemEnd() async throws {
        let reader = try await transcribedReader("Search Timing Starts")
        let transcript = try XCTUnwrap(reader.content?.transcript)
        let chapters = [
            Chapter(title: "One", text: String(repeating: " ", count: 30)),
            Chapter(title: "Two", text: String(repeating: " ", count: 20)),
        ]

        let timing = BookSearchTiming.forTranscript(transcript, audioChapters: chapters)

        XCTAssertEqual(timing.chapterStarts, [0, 3])
    }

    /// A match is heard when its sentence begins, counted from the start of
    /// the book; a chapter past the end counts from 0.
    func testAMatchIsHeardWhereItsSentenceBeginsInTheBook() async throws {
        let reader = try await transcribedReader("Search Timing Time")
        let transcript = try XCTUnwrap(reader.content?.transcript)
        let timing = BookSearchTiming(transcript: transcript, chapterStarts: [0, 3])
        let pierOffset = (try XCTUnwrap(transcript.chapterText(0)) as NSString).range(of: "pier").location

        XCTAssertEqual(timing.time(chapterIndex: 0, characterOffset: pierOffset), 1.5, accuracy: 0.001)
        XCTAssertEqual(timing.time(chapterIndex: 1, characterOffset: 20), 3, accuracy: 0.001)
        // Outside the chapters it knows, the start is 0 and the transcript
        // has no sentence to add.
        XCTAssertEqual(timing.time(chapterIndex: 7, characterOffset: 0), 0)
    }

    // MARK: - What the Reader Searches

    /// A transcribed audiobook can be searched, and its corpus is the
    /// transcript's text by audio chapter, timed from where the audio
    /// chapters begin, named by chapter title with no headings.
    func testATranscribedAudiobookSearchesItsTranscript() async throws {
        let reader = try await transcribedReader("Search Corpus Transcript")
        let transcript = try XCTUnwrap(reader.content?.transcript)

        XCTAssertTrue(reader.canSearchText)
        let corpus = try XCTUnwrap(reader.searchCorpus)
        XCTAssertEqual(corpus.chapterTexts, transcript.chapters.map(\.text))
        XCTAssertEqual(corpus.chapterTitles, reader.content?.chapters.map(\.title))
        XCTAssertTrue(corpus.headings.isEmpty)
        XCTAssertEqual(corpus.bookTitle, reader.book.title)
        let starts = try XCTUnwrap(corpus.timing?.chapterStarts)
        XCTAssertEqual(starts.count, 2)
        // Read through `[safe:]` and unwrapped, so a break in the timing
        // fails here rather than trapping the test host on the subscript.
        XCTAssertEqual(starts[safe: 0], 0)
        XCTAssertEqual(try XCTUnwrap(starts[safe: 1], "no second chapter start"), 3, accuracy: 0.11)
    }

    /// An audiobook that was never transcribed has nothing to search.
    func testAnUntranscribedAudiobookHasNothingToSearch() async throws {
        let reader = try await untranscribedReader("Search Corpus Untranscribed")

        XCTAssertNil(reader.content?.transcript)
        XCTAssertFalse(reader.canSearchText)
        XCTAssertNil(reader.searchCorpus)
    }

    // MARK: - When a Transcribed Book Shows No Text

    /// A transcribed audiobook whose audio changed since it was transcribed
    /// shows no text, and Search in Book says why in place of opening, in the
    /// stale transcript's own words, naming no command: Transcribe Audio is
    /// not offered for a book that has a transcript (its command is
    /// Retranscribe Audio…).
    func testSearchSaysWhyAStaleTranscriptShowsNoText() async throws {
        let (reader, _) = try await staleTranscriptReader("Search Stale Transcript")

        XCTAssertNil(reader.content?.transcript)
        XCTAssertFalse(reader.canSearchText)
        XCTAssertEqual(reader.transcriptWithheld, .audioChanged)

        reader.announceNoTextToSearch(hasTranscript: true)

        let said = try XCTUnwrap(reader.lastAnnouncement)
        let expected = "\(reader.book.title) has no transcript text to search now, because the audiobook's audio changed since it was "
            + "transcribed, so its transcript no longer fits it. Transcribe it again, then search the new transcript."
        XCTAssertEqual(said, expected)
        XCTAssertFalse(said.contains("Transcribe Audio"), said)

        // The library's rows may not have noted the transcript yet; the load
        // that found why its text is not shown has seen it all the same.
        reader.lastAnnouncement = nil
        reader.announceNoTextToSearch(hasTranscript: false)
        XCTAssertEqual(reader.lastAnnouncement, expected)
    }

    /// A book without a transcript is told to make one, with the command it
    /// offers, as before.
    func testSearchStillSaysToTranscribeABookWithoutATranscript() async throws {
        let reader = try await untranscribedReader("Search Untranscribed Says")

        XCTAssertNil(reader.transcriptWithheld)

        reader.announceNoTextToSearch(hasTranscript: false)

        XCTAssertEqual(reader.lastAnnouncement, BookSearchWording.noTranscript(bookTitle: reader.book.title))
    }

    /// Once text is shown, or the transcript is deleted, the reason the text
    /// was not shown no longer applies.
    func testTextThatArrivesOrGoesClearsWhyItWasNotShown() async throws {
        let (reader, text) = try await staleTranscriptReader("Search Stale Cleared")
        XCTAssertEqual(reader.transcriptWithheld, .audioChanged)

        reader.showTranscript(text)

        XCTAssertNil(reader.transcriptWithheld)
        XCTAssertTrue(reader.canSearchText)

        reader.showTranscript(nil)

        XCTAssertNil(reader.transcriptWithheld)
        XCTAssertFalse(reader.canSearchText)
    }

    /// A text book is searched as it always was: its chapters' text, no
    /// timing.
    func testATextBookSearchesItsChaptersUntimed() async throws {
        let reader = try await textBookReader("Search Corpus Text")
        let content = try XCTUnwrap(reader.content)

        XCTAssertTrue(reader.canSearchText)
        let corpus = try XCTUnwrap(reader.searchCorpus)
        XCTAssertEqual(corpus.chapterTexts, content.chapters.map(\.text))
        XCTAssertEqual(corpus.chapterTitles, content.chapters.map(\.title))
        XCTAssertEqual(corpus.headings, reader.headings)
        XCTAssertNil(corpus.timing)
    }

    /// A reader with no content yet has nothing to search.
    func testAReaderThatHasNotLoadedHasNothingToSearch() throws {
        let world = try makeIntegrationWorld("Search Corpus Unloaded")
        let source = try makeSandboxDirectory("SearchSource").appendingPathComponent("Unloaded.txt")
        try Data("Unloaded\n\nWords.".utf8).write(to: source)
        let reader = world.openReader(for: try world.importBook(from: source))

        XCTAssertFalse(reader.canSearchText)
        XCTAssertNil(reader.searchCorpus)
    }

    // MARK: - Going to a Result

    /// Choosing a result of the transcript moves the audio to its sentence,
    /// keeps where the reader was for Return and Go Back, and holds the
    /// announcement back until the sheet has closed; Go Back returns, and
    /// with nowhere left says so.
    func testChoosingAResultMovesTheAudioAndGoBackReturns() async throws {
        let reader = try await transcribedReader("Search Navigate")
        let transcript = try XCTUnwrap(reader.content?.transcript)
        let corpus = try XCTUnwrap(reader.searchCorpus)
        let ferry = try XCTUnwrap(matches("ferry", in: corpus).first)
        // Start somewhere other than the book's beginning, to tell a return
        // from a reset.
        reader.navigateTo(chapterIndex: 0, characterOffset: 12)
        XCTAssertFalse(reader.hasSavedPosition)

        reader.navigateToTranscriptSearchResult(chapterIndex: ferry.chapterIndex, textOffset: ferry.characterOffset)

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(
            reader.currentCharacterOffset,
            transcript.audioOffset(atTextOffset: ferry.characterOffset, inChapter: 1)
        )
        XCTAssertTrue(reader.hasSavedPosition)
        // The chapter's title names the place unless it only repeats the
        // book's title or is empty.
        let expectedLocations = BookSearchView.locationTitles(
            of: [(chapterIndex: 1, characterOffset: ferry.characterOffset)],
            headings: [],
            chapterTitles: try XCTUnwrap(reader.content?.chapters.map(\.title)),
            bookTitle: reader.book.title
        )
        // The one place's title (nil for a chapter whose title says nothing),
        // unwrapped from the list so no title at all fails here.
        let expectedLocation = try XCTUnwrap(expectedLocations.first, "no title was given for the place")
        let expected = BookSearchWording.movedTo(time: try XCTUnwrap(ferry.time), location: expectedLocation)
        XCTAssertEqual(reader.pendingJumpAnnouncement, expected)
        XCTAssertNotEqual(reader.lastAnnouncement, expected, "the announcement waits for the sheet to close")

        reader.announcePendingJump()
        XCTAssertEqual(reader.lastAnnouncement, expected)
        XCTAssertNil(reader.pendingJumpAnnouncement)

        reader.goBack()
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 12)
        XCTAssertFalse(reader.hasSavedPosition)
        XCTAssertEqual(reader.lastAnnouncement, "Returned to previous position")

        reader.goBack()
        XCTAssertEqual(reader.lastAnnouncement, BookSearchWording.nothingToGoBackTo)
        XCTAssertEqual(reader.currentChapterIndex, 0)
    }

    /// `goToSearchResult` takes the transcript's move for a transcript's
    /// result, to the sentence holding the match with "Moved to" waiting, and
    /// the text book's move otherwise, to the match itself with nothing waiting.
    func testGoToSearchResultChoosesTheMoveByTheBookSearched() async throws {
        let reader = try await transcribedReader("Search Go To Result")
        let transcript = try XCTUnwrap(reader.content?.transcript)
        let corpus = try XCTUnwrap(reader.searchCorpus)
        let ferry = try XCTUnwrap(matches("ferry", in: corpus).first)

        reader.goToSearchResult(chapterIndex: ferry.chapterIndex, characterOffset: ferry.characterOffset, inTranscript: true)

        XCTAssertEqual(
            reader.currentCharacterOffset,
            transcript.audioOffset(atTextOffset: ferry.characterOffset, inChapter: ferry.chapterIndex),
            "A transcript result didn't move the audio to its sentence"
        )
        XCTAssertNotNil(reader.pendingJumpAnnouncement, "A transcript result left no \"Moved to\" waiting")
        XCTAssertTrue(reader.hasSavedPosition)
        reader.announcePendingJump()

        reader.goToSearchResult(chapterIndex: 0, characterOffset: 7, inTranscript: false)

        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 7, "A text result moved by the transcript's text-to-audio map")
        XCTAssertNil(reader.pendingJumpAnnouncement)
    }

    /// Without a transcript, a transcript result moves nothing and says
    /// nothing; announcing with none pending says nothing either.
    func testWithoutATranscriptNothingMoves() async throws {
        let reader = try await untranscribedReader("Search Navigate None")
        let spoken = reader.lastAnnouncement

        reader.navigateToTranscriptSearchResult(chapterIndex: 1, textOffset: 0)
        reader.announcePendingJump()

        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertFalse(reader.hasSavedPosition)
        XCTAssertNil(reader.pendingJumpAnnouncement)
        XCTAssertEqual(reader.lastAnnouncement, spoken)
    }

    // MARK: - The Sheet's Rows

    /// A row of a transcript's result shows the exact time where the
    /// position goes and speaks its timed label, whatever display mode the
    /// untimed rows would use.
    func testATimedRowShowsAndSpeaksItsTime() async throws {
        let reader = try await transcribedReader("Search Row Timed")
        let corpus = try XCTUnwrap(reader.searchCorpus)
        let pier = try XCTUnwrap(matches("pier", in: corpus).first)

        for mode in BookSearchView.DisplayMode.allCases {
            let row = SearchResultRow(
                result: pier,
                displayMode: mode,
                totalCharacterCount: 500,
                totalWordCount: 80,
                currentWPM: 200
            )
            XCTAssertEqual(row.positionText, "0:01")
            XCTAssertEqual(row.accessibilityDescription, try XCTUnwrap(pier.timedLabel))
        }
        XCTAssertTrue(try XCTUnwrap(pier.timedLabel).hasSuffix(", at 1 second"))
    }

    /// A row of a text book's result is as it was: the estimate in the
    /// display mode chosen.
    func testAnUntimedRowStillGivesItsEstimate() throws {
        let corpus = BookSearchCorpus(
            chapterTexts: ["The ferry leaves at dawn."],
            chapterTitles: ["Crossing"],
            headings: [],
            bookTitle: "Slip Notes"
        )
        let result = try XCTUnwrap(matches("ferry", in: corpus).first)

        let percentage = SearchResultRow(
            result: result,
            displayMode: .percentage,
            totalCharacterCount: 100,
            totalWordCount: 20,
            currentWPM: 200
        )
        XCTAssertEqual(percentage.positionText, "4.0%")
        XCTAssertEqual(percentage.accessibilityDescription, "\(result.contextAndLocation), at 4.0 percent of book")
    }

    /// The Display picker, which chooses how an estimate is shown, is in
    /// the sheet of a text book and not in a transcript's, whose times are
    /// exact.
    func testOnlyAnUntimedSearchOffersTheDisplayPicker() async throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let reader = try await transcribedReader("Search Picker")
        let timed = try XCTUnwrap(reader.searchCorpus)
        let untimed = BookSearchCorpus(chapterTexts: ["Text."], chapterTitles: [""], headings: [], bookTitle: "Slip Notes")

        for (corpus, expectedPickers) in [(timed, 0), (untimed, 1)] {
            let sheet = BookSearchView(
                corpus: corpus,
                totalCharacterCount: 100,
                totalWordCount: 20,
                currentWPM: 200,
                announce: { _ in },
                onNavigate: { _, _ in }
            )
            let hosted = hostOffscreen(sheet, size: NSSize(width: 500, height: 450))
            defer { takeDown(hosted.window) }
            XCTAssertEqual(
                descendants(of: hosted.hostingView, as: NSSegmentedControl.self).count,
                expectedPickers,
                corpus.timing == nil ? "a text book's search has the picker" : "a transcript's search has none"
            )
        }
    }

    // MARK: - Wording

    /// Each sentence the search speaks, word for word.
    func testTheSearchWordingIsPinned() {
        XCTAssertEqual(
            BookSearchWording.noTranscript(bookTitle: "Breakwater Notes"),
            "Breakwater Notes has no transcript to search. Transcribe it first, with Transcribe Audio."
        )
        XCTAssertEqual(
            BookSearchWording.movedTo(time: 3725, location: "Crossing"),
            "Moved to 1 hour, 2 minutes, 5 seconds, Crossing."
        )
        XCTAssertEqual(BookSearchWording.movedTo(time: 54, location: nil), "Moved to 54 seconds.")
        XCTAssertEqual(BookSearchWording.nothingToGoBackTo, "No previous position to return to.")
        XCTAssertEqual(BookSearchWording.transcriptFieldHint, "Type to search the book's transcript")
    }

    /// What Search says in place of opening for a transcribed audiobook that
    /// shows no text, word for word: no command is named but for a book
    /// without a transcript that offers to transcribe its audio.
    func testWhatSearchSaysWhenATranscribedBookShowsNoTextIsPinned() {
        let copy = URL(fileURLWithPath: "content.md.edited-20261023T093000Z")
        func said(_ withheld: TranscriptTextWithheld?, hasTranscript: Bool = true, canTranscribe: Bool = true) -> String {
            BookSearchWording.noTextToSearch(
                bookTitle: "Breakwater Notes", canTranscribe: canTranscribe, hasTranscript: hasTranscript, withheld: withheld
            )
        }
        let lead = "Breakwater Notes has no transcript text to search now"

        // No transcript: the command that makes one, when the book offers it.
        XCTAssertEqual(
            said(nil, hasTranscript: false),
            "Breakwater Notes has no transcript to search. Transcribe it first, with Transcribe Audio."
        )
        XCTAssertEqual(said(nil, hasTranscript: false, canTranscribe: false), "Breakwater Notes has no transcript to search.")
        // A transcript whose text is not shown: why, in the words that say it elsewhere.
        XCTAssertEqual(said(nil), lead + ".")
        XCTAssertEqual(
            said(.textInCloud),
            lead + ". The book's text is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again."
        )
        XCTAssertEqual(
            said(.transcriptInCloud),
            lead + ". The book's transcript is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again."
        )
        XCTAssertEqual(
            said(.audioChanged),
            lead + ", because the audiobook's audio changed since it was transcribed, so its transcript no longer fits it. "
                + "Transcribe it again, then search the new transcript."
        )
        XCTAssertEqual(
            said(.editHeld(.headingChanged, keptCopy: copy)),
            lead + ", because its edited text can't be used: it changes a chapter's heading, which comes from the audio. "
                + "Put the heading back as it was and save again, and the text shows. "
                + "Your edited text was also kept as content.md.edited-20261023T093000Z, in the book's package."
        )
        XCTAssertEqual(
            said(.editHeld(.notText, keptCopy: nil)),
            lead + ", because its edited text can't be used: it isn't UTF-8 text. Save it as UTF-8 in your editor, "
                + "and the text shows. No copy of your edited text could be kept, so TextMouth leaves content.md as it is."
        )
        // None of them names a command: a book with a transcript offers
        // Retranscribe Audio…, which replaces it.
        let reasons: [TranscriptTextWithheld?] = [nil, .textInCloud, .transcriptInCloud, .audioChanged, .editHeld(.noChapters, keptCopy: copy)]
        for reason in reasons {
            XCTAssertFalse(said(reason).contains("Transcribe Audio"), said(reason))
            XCTAssertFalse(said(reason).contains("Retranscribe"), said(reason))
        }

        // The words the held edit and the stale transcript share with their
        // other sentences are those sentences' own.
        XCTAssertEqual(
            BookTextEditWording.held(.noChapters, bookTitle: "Breakwater Notes", keptCopy: nil),
            "Breakwater Notes can't open while its edited text can't be used: it has no chapter left with anything in it. "
                + "Undo the change in your editor and save again, and the book opens. "
                + "No copy of your edited text could be kept, so TextMouth leaves content.md as it is."
        )
        XCTAssertEqual(
            BookTextEditWording.transcriptStale,
            "the audiobook's audio changed since it was transcribed, so its transcript no longer fits it. "
                + "Transcribe it again, then edit the new transcript."
        )
    }

    // MARK: - Timed Results

    /// A search with timing gives each result its time and a spoken label
    /// that ends with it; one without timing is as it always was.
    func testResultsOfATimedSearchSayWhenTheyAreHeard() async throws {
        let reader = try await transcribedReader("Search Timed Results")
        let corpus = try XCTUnwrap(reader.searchCorpus)

        let pier = try matches("pier", in: corpus)
        let ferry = try matches("ferry", in: corpus)

        XCTAssertEqual(pier.map(\.chapterIndex), [0])
        XCTAssertEqual(try XCTUnwrap(pier.first?.time), 1.5, accuracy: 0.001)
        XCTAssertEqual(ferry.map(\.chapterIndex), [1])
        XCTAssertEqual(try XCTUnwrap(ferry.first?.time), 3, accuracy: 0.001)
        for result in pier + ferry {
            XCTAssertEqual(
                result.timedLabel,
                "\(result.contextAndLocation), at \(TimeFormatting.spoken(try XCTUnwrap(result.time)))"
            )
        }
    }

    /// Without timing a result has no time and no timed label.
    func testResultsOfAnUntimedSearchHaveNoTime() throws {
        let corpus = BookSearchCorpus(
            chapterTexts: ["The ferry leaves at dawn."],
            chapterTitles: ["Crossing"],
            headings: [],
            bookTitle: "Slip Notes"
        )

        let results = try matches("ferry", in: corpus)

        XCTAssertEqual(results.count, 1)
        // Unwrapped, so a search that found nothing fails here rather than
        // trapping the test host on the subscript.
        let result = try XCTUnwrap(results.first, "the search found no result")
        XCTAssertNil(result.time)
        XCTAssertNil(result.timedLabel)
    }

    /// The results of a plain search for `query` in `corpus`.
    private func matches(_ query: String, in corpus: BookSearchCorpus) throws -> [BookSearchResult] {
        guard case .matches(let results, _) = try BookSearchEngine.search(query: query, useRegex: false, in: corpus) else {
            XCTFail("the search of \(query) found no outcome")
            return []
        }
        return results
    }
}
