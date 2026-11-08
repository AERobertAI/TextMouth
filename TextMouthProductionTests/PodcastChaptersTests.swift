import XCTest
@testable import TextMouth

/// `PodcastChapters` reads a podcast episode's chapters file (Podcasting
/// 2.0, version 1.2.0) into the chapters its table of contents lists, writes
/// them as the normalized file kept beside the episode's audio, and turns
/// them into a book's chapters (FMT25). The sample is copied into the test's
/// own folder first; every other case is a small file made here. No test
/// plays sound or opens audio.
final class PodcastChaptersTests: XCTestCase {
    // MARK: - Helpers

    /// A chapters file listing `chapters`, of `version` (left out when nil),
    /// as JSON bytes.
    private func chaptersFile(_ chapters: [Any], version: Any? = "1.2.0") throws -> Data {
        var file: [String: Any] = ["chapters": chapters]
        file["version"] = version
        return try podcastingJSON(file)
    }

    /// A chapter whose fields hold exactly the values given, so a case can
    /// give any of them as a number, as text, or as anything else; a nil
    /// field is left out.
    private func chapter(_ startTime: Any?, title: Any? = nil, toc: Any? = nil) -> [String: Any] {
        var fields: [String: Any] = [:]
        fields["startTime"] = startTime
        fields["title"] = title
        fields["toc"] = toc
        return fields
    }

    /// A chapter as TextMouth keeps it, beginning at `start` milliseconds.
    private func kept(_ start: Int, _ title: String) -> PodcastChapter {
        PodcastChapter(startMilliseconds: start, title: title)
    }

    /// Each chapter of `chapters` on one line, as "2500: Third, with a
    /// place": its start in milliseconds, and its title.
    private func lines(_ chapters: PodcastChapters) -> [String] {
        chapters.chapters.map { "\($0.startMilliseconds): \($0.title)" }
    }

    /// The sample's chapters, read from a copy of it.
    private func sampleChapters() throws -> PodcastChapters {
        try PodcastChapters.read(Data(contentsOf: copyOfFormatSample("podcast-chapters-json/chapters.json")))
    }

    /// Asserts that `times` are `expected`, each to within a millisecond.
    private func assertTimes(
        _ times: [TimeInterval],
        _ expected: [TimeInterval],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(times.count, expected.count, "\(times)", file: file, line: line)
        for (time, expectedTime) in zip(times, expected) {
            XCTAssertEqual(time, expectedTime, accuracy: 0.001, "\(times)", file: file, line: line)
        }
    }

    /// Asserts that reading `data` throws `expected`.
    private func assertRefuses(
        _ data: Data,
        with expected: PodcastChaptersError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PodcastChapters.read(data), file: file, line: line) { error in
            XCTAssertEqual(error as? PodcastChaptersError, expected, file: file, line: line)
        }
    }

    // MARK: - The Sample

    /// The sample lists five chapters: the four of its table of contents are
    /// read, in order, each with its start and title, and the one marked
    /// `toc: false` is left out. Its other fields (a chapter's end, link,
    /// picture, and place, and the file's title and author) are not kept.
    func testTheSampleReadsAsTheFourChaptersOfItsTableOfContents() throws {
        XCTAssertEqual(try sampleChapters(), PodcastChapters(chapters: [
            kept(0, "Intro — 440 Hz"),
            kept(1_000, "Second: café"),
            kept(2_500, "Third, with a place"),
            kept(3_200, "Outro"),
        ]))
    }

    // MARK: - What Is Not a Chapters File

    /// What is not a chapters file is refused as one: bytes that are not
    /// JSON, no bytes, an array at the top, a file without a "chapters" key,
    /// and chapters that are not a list.
    func testWhatIsNotAChaptersFileIsRefused() throws {
        let cases = try [
            Data("Chapters: Intro at 0:00".utf8),
            Data(),
            podcastingJSON([chapter(0, title: "Intro")]),
            podcastingJSON(["version": "1.2.0", "title": "An episode"]),
            podcastingJSON(["version": "1.2.0", "chapters": chapter(0, title: "Intro")] as [String: Any]),
        ]
        for data in cases {
            assertRefuses(data, with: .notChapters)
        }
    }

    /// A file of major version 1 is read however it writes its version, as
    /// is one whose version is a number rather than text, and one that gives
    /// none; another major version is refused, naming the version as the
    /// file gives it, cut to its first 20 characters.
    func testVersionOneIsReadAndAnotherRefusedByName() throws {
        let intro = [chapter(0, title: "Intro")]
        for version: Any? in ["1.2.0", "1", "1.0", 1.2, nil] {
            XCTAssertEqual(try lines(PodcastChapters.read(chaptersFile(intro, version: version))), ["0: Intro"],
                           "version \(String(describing: version))")
        }

        assertRefuses(try chaptersFile(intro, version: "2.0"), with: .unsupportedVersion("2.0"))
        let long = "3.0.0-" + String(repeating: "x", count: 34)
        XCTAssertEqual(long.count, 40)
        assertRefuses(try chaptersFile(intro, version: long), with: .unsupportedVersion("3.0.0-xxxxxxxxxxxxxx"))
    }

    /// A file listing more than 5,000 chapters is refused before any is
    /// read, even when none of them could be used; one listing exactly
    /// 5,000 is read whole.
    func testMoreThanTheMostChaptersIsRefusedBeforeAnyIsRead() throws {
        XCTAssertEqual(PodcastChapters.maximumChapters, 5_000)

        assertRefuses(try chaptersFile(Array(repeating: "not a chapter", count: 5_001)), with: .tooManyChapters(limit: 5_000))
        assertRefuses(try chaptersFile((0..<5_001).map { chapter($0, title: "Part") }), with: .tooManyChapters(limit: 5_000))

        let most = try PodcastChapters.read(chaptersFile((0..<5_000).map { chapter($0, title: "Part") }))
        XCTAssertEqual(most.chapters.count, 5_000)
    }

    /// A file whose list is empty, holds no chapter that can be used, or
    /// holds only chapters out of the table of contents is refused as
    /// listing none.
    func testAFileWithNoUsableChapterIsRefused() throws {
        assertRefuses(try chaptersFile([]), with: .noChapters)
        assertRefuses(try chaptersFile(["Intro", chapter(nil, title: "No start")]), with: .noChapters)
        assertRefuses(try chaptersFile([chapter(0, title: "Hidden", toc: false)]), with: .noChapters)
    }

    // MARK: - Each Chapter

    /// A chapter is passed over when it is not an object, or its start is
    /// missing, negative, true, text that reads as no finite number, or
    /// later than the latest moment a time may be; a start given as text
    /// holding a number is read, and so is one at that latest moment.
    func testChaptersWithUnusableStartsArePassedOver() throws {
        let maximum = Transcript.maximumMilliseconds
        let chapters = try PodcastChapters.read(chaptersFile([
            "Intro",
            NSNull(),
            chapter(nil, title: "No start"),
            chapter(-1, title: "Negative"),
            chapter(true, title: "A truth"),
            chapter("nan", title: "Not a number"),
            chapter("inf", title: "Not finite"),
            chapter("later", title: "Not a time"),
            chapter(Double(maximum + 1) / 1_000, title: "Past the maximum"),
            chapter(Double(maximum) / 1_000, title: "At the maximum"),
            chapter("62.5", title: "As text"),
        ]))

        XCTAssertEqual(lines(chapters), ["62500: As text", "\(maximum): At the maximum"])
    }

    /// A chapter marked out of the table of contents, by JSON's false or by
    /// the text "false" in any letter case, is left out; one marked true, or
    /// by anything else (0, null), or not marked, is kept.
    func testChaptersOutOfTheTableOfContentsAreLeftOut() throws {
        let chapters = try PodcastChapters.read(chaptersFile([
            chapter(0, title: "False", toc: false),
            chapter(1, title: "False as text", toc: "false"),
            chapter(2, title: "False as capitalized text", toc: "False"),
            chapter(3, title: "True", toc: true),
            chapter(4, title: "Zero", toc: 0),
            chapter(5, title: "Null", toc: NSNull()),
            chapter(6, title: "Not marked"),
        ]))

        XCTAssertEqual(lines(chapters), ["3000: True", "4000: Zero", "5000: Null", "6000: Not marked"])
    }

    /// A chapter's title is finished as a cue's text is; one that is
    /// missing, not text, or blank is kept as an empty title, which a book
    /// names by the chapter's place.
    func testTitlesAreFinishedAndAMissingOneIsKeptEmpty() throws {
        let chapters = try PodcastChapters.read(chaptersFile([
            chapter(0, title: "  Opening\n remarks\t "),
            chapter(1),
            chapter(2, title: 42),
            chapter(3, title: " \n "),
        ]))

        XCTAssertEqual(chapters.chapters.map(\.title), ["Opening remarks", "", "", ""])
        XCTAssertEqual(chapters.bookChapters(fileDuration: 10).map(\.title), ["Opening remarks", "Chapter 2", "Chapter 3", "Chapter 4"])
    }

    /// Chapters are put in the order they begin, and those that begin
    /// together keep the file's order.
    func testChaptersAreOrderedByStartKeepingTheFilesOrderForTies() throws {
        let chapters = try PodcastChapters.read(chaptersFile([
            chapter(30, title: "Third"),
            chapter(0, title: "First"),
            chapter(10, title: "Second, listed first"),
            chapter(10, title: "Second, listed second"),
        ]))

        XCTAssertEqual(lines(chapters), ["0: First", "10000: Second, listed first", "10000: Second, listed second", "30000: Third"])
    }

    /// Each reason a chapters file is not used is worded for the log,
    /// exactly, and never quotes a title.
    func testEachReasonIsWordedForTheLog() {
        XCTAssertEqual(PodcastChaptersError.notChapters.description, "not a chapters file")
        XCTAssertEqual(PodcastChaptersError.unsupportedVersion("2.0").description, "version 2.0 is not one TextMouth reads")
        XCTAssertEqual(PodcastChaptersError.noChapters.description, "it lists no chapter TextMouth can use")
        XCTAssertEqual(PodcastChaptersError.tooManyChapters(limit: 5_000).description, "it lists more than 5000 chapters")
    }

    // MARK: - The Normalized File

    /// The normalized file holds version 1.2.0 and, for each chapter, only
    /// its start in seconds and its title, with its keys sorted, so the same
    /// chapters always give the same bytes.
    func testTheNormalizedFileHoldsOnlyEachStartAndTitle() throws {
        let chapters = PodcastChapters(chapters: [kept(0, "Intro"), kept(62_500, "Second: café")])

        XCTAssertEqual(
            String(decoding: try chapters.normalizedJSON(), as: UTF8.self),
            #"{"chapters":[{"startTime":0,"title":"Intro"},{"startTime":62.5,"title":"Second: café"}],"version":"1.2.0"}"#
        )
    }

    /// Reading the sample's normalized file gives back the sample's chapters.
    func testTheSamplesNormalizedFileReadsBackAsTheSameChapters() throws {
        let chapters = try sampleChapters()

        XCTAssertEqual(try PodcastChapters.read(chapters.normalizedJSON()), chapters)
    }

    // MARK: - The Book's Chapters

    /// Over the sample's own 4-second audio, the chapters begin at 0, 1,
    /// 2.5, and 3.2 seconds, each lasting until the next begins and the
    /// last until the end.
    func testTheSamplesChaptersOverItsFourSecondAudio() throws {
        let book = try sampleChapters().bookChapters(fileDuration: 4)

        XCTAssertEqual(book.map(\.title), ["Intro — 440 Hz", "Second: café", "Third, with a place", "Outro"])
        assertTimes(book.map(\.startTime), [0, 1, 2.5, 3.2])
        assertTimes(book.map(\.duration), [1, 1.5, 0.7, 0.8])
    }

    /// A last chapter that begins 5 seconds past the end of the audio is
    /// within the margin: the file is taken for this audio, and that
    /// chapter, lying past the end, is dropped while the others stay. One
    /// that begins 5.001 seconds past the end means the file was made for
    /// other audio, and gives no chapters at all.
    func testALastChapterPastTheMarginGivesNoChapters() {
        let within = PodcastChapters(chapters: [kept(0, "Start"), kept(2_000, "Middle"), kept(9_000, "Past the end")])
        XCTAssertEqual(within.bookChapters(fileDuration: 4).map(\.title), ["Start", "Middle"])

        let beyond = PodcastChapters(chapters: [kept(0, "Start"), kept(2_000, "Middle"), kept(9_001, "Past the margin")])
        XCTAssertTrue(beyond.bookChapters(fileDuration: 4).isEmpty)
    }

    /// A first chapter that begins after the audio does is moved to its
    /// start, so the chapters cover the whole file.
    func testAFirstChapterBeginningLateIsMovedToTheStart() {
        let book = PodcastChapters(chapters: [kept(12_000, "Late"), kept(20_000, "Next")]).bookChapters(fileDuration: 30)

        XCTAssertEqual(book.map(\.title), ["Late", "Next"])
        assertTimes(book.map(\.startTime), [0, 20])
        assertTimes(book.map(\.duration), [20, 10])
    }

    /// Audio whose length is not a finite number above zero gives no
    /// chapters, as Nero's rules give none.
    func testAnUnknownLengthGivesNoChapters() throws {
        let chapters = try sampleChapters()

        for unknown: TimeInterval in [0, -1, .nan, .infinity] {
            XCTAssertTrue(chapters.bookChapters(fileDuration: unknown).isEmpty, "length \(unknown)")
        }
    }
}
