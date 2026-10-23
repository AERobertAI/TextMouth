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

    // MARK: - Timed Results

    /// A search with timing gives each result its time and a spoken label
    /// that ends with it; one without timing is as it always was.
    func testResultsOfATimedSearchSayWhenTheyAreHeard() async throws {
        let reader = try await transcribedReader("Search Timed Results")
        let corpus = try timedCorpus(of: reader)

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
        XCTAssertNil(results[0].time)
        XCTAssertNil(results[0].timedLabel)
    }

    /// The corpus of `reader`'s transcript, timed from chapters of 3 and 2
    /// seconds.
    private func timedCorpus(of reader: ReaderViewModel) throws -> BookSearchCorpus {
        let transcript = try XCTUnwrap(reader.content?.transcript)
        return BookSearchCorpus(
            chapterTexts: transcript.chapters.map(\.text),
            chapterTitles: transcript.chapters.map(\.title),
            headings: [],
            bookTitle: reader.book.title,
            timing: BookSearchTiming(transcript: transcript, chapterStarts: [0, 3])
        )
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
