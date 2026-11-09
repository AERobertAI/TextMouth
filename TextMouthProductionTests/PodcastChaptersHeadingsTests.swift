import XCTest
@testable import TextMouth

/// A podcast episode's chapters, kept beside its audio in its package as
/// podcastChapters.json (FMT25), become the chapters, and so the headings,
/// of a book of one file whose audio has no chapters of its own, when they
/// fit the audio. The file is TextMouth's own, never taken for the book; it
/// goes with the audio when an episode's download is deleted; and an edit
/// of the audio drops it, since its times no longer fit. The chapters come
/// from a copy of the format sample or are made here; every audio file is
/// written here, and none is played.
@MainActor
final class PodcastChaptersHeadingsTests: XCTestCase {
    // MARK: - Helpers

    /// The titles of the sample's four chapters in its table of contents,
    /// in order.
    private static let sampleTitles = ["Intro — 440 Hz", "Second: café", "Third, with a place", "Outro"]

    /// The sample's chapters, read from a copy of it.
    private func sampleChapters() throws -> PodcastChapters {
        try PodcastChapters.read(Data(contentsOf: copyOfFormatSample("podcast-chapters-json/chapters.json")))
    }

    /// The sample's chapters as the file an episode's download keeps
    /// beside its audio (`PodcastChapters.normalizedJSON()`).
    private func sampleChaptersFile() throws -> Data {
        try sampleChapters().normalizedJSON()
    }

    /// A silent WAV file lasting `duration` seconds, named `name`, in a new
    /// folder of this test's own.
    private func silentFile(named name: String, duration: TimeInterval) throws -> URL {
        let file = try makeSandboxDirectory("PodcastChaptersAudio").appendingPathComponent(name)
        try AudioTestFixtures.writeSilence(to: file, duration: duration)
        return file
    }

    /// Each heading of `content`, chapter by chapter, as "level chapter
    /// offset: text", such as "1 0 0: Outro".
    private func headingLines(of content: DocumentContent) -> [[String]] {
        content.chapters.map { chapter in
            chapter.headings.map { "\($0.level) \($0.chapterIndex) \($0.characterOffset): \($0.text)" }
        }
    }

    /// `title` made unique, so a test reads only its own lines of the debug
    /// log, which every test of the run writes to.
    private func uniqueTitle(_ title: String) -> String {
        "\(title) \(UUID().uuidString.prefix(8))"
    }

    /// An audiobook of one file, named `fileName` and written by
    /// `writeAudio`, titled `title`, in `world`, with `chapters`, the bytes
    /// of a chapters file, beside its audio as podcastChapters.json, as an
    /// episode's download keeps them; indexed as an import indexes it.
    private func makeEpisode(
        in world: IntegrationWorld,
        title: String,
        fileName: String,
        keeping chapters: Data,
        writingAudio writeAudio: (URL) throws -> Void
    ) throws -> Book {
        try world.makeOneFileAudioBook(title: title, fileName: fileName) { file in
            try writeAudio(file)
            try chapters.write(to: TextMouthPaths.podcastChaptersPath(in: file.deletingLastPathComponent()))
        }
    }

    /// `makeEpisode` with a silent WAV file lasting `duration` seconds,
    /// named after the title.
    private func makeSilentEpisode(
        in world: IntegrationWorld,
        title: String,
        duration: TimeInterval,
        keeping chapters: Data
    ) throws -> Book {
        try makeEpisode(in: world, title: title, fileName: "\(title).wav", keeping: chapters) { file in
            try AudioTestFixtures.writeSilence(to: file, duration: duration)
        }
    }

    /// The text of each heading of `book`'s index, read as the reader reads
    /// it (`BookContentAnalysisService.load`).
    private func indexedHeadings(of book: Book) throws -> [String] {
        try BookContentAnalysisService.load(book: book).index.allHeadings.map(\.text)
    }

    /// The debug log's lines holding `text`, each from `text` on, without
    /// the time that begins it.
    private func loggedLines(from text: String) -> [String] {
        debugLogLines(containing: text).compactMap { line in
            line.range(of: text).map { String(line[$0.lowerBound...]) }
        }
    }

    /// How a log line names `error`: by its code and domain, never in its
    /// own words, which can name a folder by its absolute path.
    private func loggedName(of error: Error) -> String {
        let failure = error as NSError
        return "error \(failure.code) in \(failure.domain)"
    }

    /// The error `operation` throws, as the test expects it to; nil, with
    /// the test failed, when it throws none.
    private func thrownError(
        by operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Error? {
        do {
            try operation()
        } catch {
            return error
        }
        XCTFail("nothing was thrown", file: file, line: line)
        return nil
    }

    /// `json` followed by spaces, which JSON allows after its value, to
    /// `count` bytes in all.
    private func padded(_ json: Data, to count: Int) -> Data {
        json + Data(repeating: UInt8(ascii: " "), count: max(0, count - json.count))
    }

    /// Two chapters, the second beginning `lastStart` milliseconds in.
    private func twoChapters(lastBeginningAt lastStart: Int) -> PodcastChapters {
        PodcastChapters(chapters: [
            PodcastChapter(startMilliseconds: 0, title: "Opening"),
            PodcastChapter(startMilliseconds: lastStart, title: "After the Break"),
        ])
    }

    /// The two chapter markers of the chaptered files these tests write:
    /// one second, then two.
    private static let ownMarkers = [
        AudioTestFixtures.ChapterMarker(title: "Harbor Approach", start: 0, duration: 1),
        AudioTestFixtures.ChapterMarker(title: "Breakwater Survey", start: 1, duration: 2),
    ]

    // MARK: - The File

    /// The chapters are podcastChapters.json at the top of the package, a
    /// file of TextMouth's own that is never taken for the book: a package
    /// holding an episode's audio and its chapters is the audio's.
    func testTheChaptersFileIsNamedInThePackageAndNeverTakenForTheBook() throws {
        XCTAssertEqual(TextMouthPaths.podcastChaptersFileName, "podcastChapters.json")
        let package = try makeSandboxDirectory("PodcastChaptersPackage")
        XCTAssertEqual(
            TextMouthPaths.podcastChaptersPath(in: package),
            package.appendingPathComponent("podcastChapters.json")
        )
        XCTAssertFalse(FileImportService.isPackageContentName("podcastChapters.json"))

        try Data().write(to: package.appendingPathComponent("Episode.mp3"))
        try sampleChaptersFile().write(to: TextMouthPaths.podcastChaptersPath(in: package))
        XCTAssertEqual(try FileImportService.retainedContentURL(in: package).lastPathComponent, "Episode.mp3")
    }

    // MARK: - The Parser

    /// A file without chapters of its own takes the podcast's chapters that
    /// fit it, each a chapter headed by its title, its placeholder as long
    /// as its stretch of the audio: the sample's four over 4 seconds.
    func testAFileWithoutChaptersTakesThePodcastsChapters() async throws {
        let file = try silentFile(named: "Four Tones.wav", duration: 4)
        let chapters = try sampleChapters()

        let content = try await AudioBookParser.parse(url: file, fallbackChapters: chapters)

        XCTAssertEqual(content.title, "Four Tones")
        XCTAssertEqual(content.chapters.map(\.title), Self.sampleTitles)
        XCTAssertEqual(headingLines(of: content), [
            ["1 0 0: Intro — 440 Hz"], ["1 1 0: Second: café"], ["1 2 0: Third, with a place"], ["1 3 0: Outro"],
        ])
        // Each chapter lasts until the next begins, the last until the end
        // of the audio: 1, 1.5, 0.7, and 0.8 seconds, written as the
        // differences the parser takes. A placeholder's length is truncated,
        // and 4 − 3.2 is a hair under 0.8 in binary, so the lengths are 10,
        // 15, 7, and 7 characters, as a file's own chapters of those times
        // would have.
        let stretches: [TimeInterval] = [1 - 0, 2.5 - 1, 3.2 - 2.5, 4 - 3.2]
        XCTAssertEqual(content.chapters.map(\.text.count), stretches.map(AudioBookParser.placeholderLength(for:)))

        let parsed = try await AudioBookParser.parseFile(url: file, fallbackChapters: chapters)
        XCTAssertEqual(parsed.chapterSource, .podcastChapters)
    }

    /// A file with chapters of its own keeps them, though a podcast's
    /// chapters are given that would fit its 3 seconds too.
    func testAFileWithChaptersOfItsOwnKeepsThem() async throws {
        let file = try makeSandboxDirectory("PodcastChaptersAudio").appendingPathComponent("Harbor Lectures.m4a")
        try await AudioTestFixtures.writeChapteredAAC(to: file, duration: 3, chapters: Self.ownMarkers)
        let chapters = try sampleChapters()

        let parsed = try await AudioBookParser.parseFile(url: file, fallbackChapters: chapters)

        XCTAssertEqual(parsed.chapterSource, .file)
        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Harbor Approach", "Breakwater Survey"])
        XCTAssertEqual(headingLines(of: parsed.content), [["1 0 0: Harbor Approach"], ["1 1 0: Breakwater Survey"]])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 20])
    }

    /// Chapters whose last begins more than 5 seconds past the end of the
    /// audio were made for other audio: none is taken, and the file is the
    /// one chapter it is without them.
    func testChaptersBeginningPastTheEndGiveTheOneChapterOfToday() async throws {
        let file = try silentFile(named: "Four Tones.wav", duration: 4)

        let parsed = try await AudioBookParser.parseFile(url: file, fallbackChapters: twoChapters(lastBeginningAt: 9_001))

        XCTAssertEqual(parsed.chapterSource, .wholeFile)
        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Four Tones"])
        XCTAssertEqual(headingLines(of: parsed.content), [["1 0 0: Four Tones"]])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [40])
    }

    /// Without a podcast's chapters, a file without chapters of its own is
    /// parsed exactly as before: one chapter, named and headed by the
    /// file's name, ten placeholder characters a second.
    func testWithoutPodcastChaptersAFileIsParsedAsBefore() async throws {
        let file = try silentFile(named: "Four Tones.wav", duration: 4)

        let content = try await AudioBookParser.parse(url: file, fallbackChapters: nil)

        XCTAssertEqual(content.title, "Four Tones")
        XCTAssertEqual(content.author, Book.unknownAuthor)
        XCTAssertEqual(content.chapters.map(\.title), ["Four Tones"])
        XCTAssertEqual(headingLines(of: content), [["1 0 0: Four Tones"]])
        XCTAssertEqual(content.chapters.map(\.text.count), [40])
        let parsed = try await AudioBookParser.parseFile(url: file)
        XCTAssertEqual(parsed.chapterSource, .wholeFile)
    }

    // MARK: - The Book's Chapters

    /// A podcast's chapters, one for each of `starts` (seconds), titled
    /// "One", "Two", and so on, as a book of `fileDuration` seconds takes
    /// them.
    private func bookChapters(
        starting starts: [TimeInterval],
        fileDuration: TimeInterval
    ) -> [(title: String, startTime: TimeInterval, duration: TimeInterval)] {
        let titles = ["One", "Two", "Three", "Four", "Five"]
        return PodcastChapters(chapters: starts.enumerated().map { place, start in
            PodcastChapter(startMilliseconds: Int((start * 1_000).rounded()), title: titles[place % titles.count])
        }).bookChapters(fileDuration: fileDuration)
    }

    /// The margin is decision 6's 5 seconds: a last chapter that begins
    /// exactly that far past the end of the audio is still the audio's (its
    /// own chapter is past the end, so Nero's rules drop it), and one
    /// millisecond further was made for other audio and gives none.
    func testTheLastChapterMayBeginFiveSecondsPastTheEndButNotMore() {
        let atTheMargin = twoChapters(lastBeginningAt: 9_000).bookChapters(fileDuration: 4)
        XCTAssertEqual(atTheMargin.map(\.title), ["Opening"])
        XCTAssertEqual(atTheMargin.map(\.duration), [4])

        XCTAssertEqual(twoChapters(lastBeginningAt: 9_001).bookChapters(fileDuration: 4).count, 0)
    }

    /// A length that is no usable number gives no chapters, and never traps.
    func testALengthThatIsNoUsableNumberGivesNoChapters() {
        for duration in [0, -1, TimeInterval.nan, .infinity, -.infinity] as [TimeInterval] {
            XCTAssertEqual(twoChapters(lastBeginningAt: 1_000).bookChapters(fileDuration: duration).count, 0, "\(duration)")
        }
    }

    /// Nero's rules, as they bear on a podcast's chapters: the first chapter
    /// begins at 0 whatever its time, a repeated start keeps the first, a
    /// chapter at or past the end is dropped, each lasts until the next, and
    /// a title that is nothing is named by its place among those kept.
    func testNerosRulesShapeThePodcastsChapters() {
        let chapters = PodcastChapters(chapters: [
            PodcastChapter(startMilliseconds: 30_000, title: "Interview"),
            PodcastChapter(startMilliseconds: 30_000, title: "Repeated"),
            PodcastChapter(startMilliseconds: 60_000, title: " \u{200B} "),
            PodcastChapter(startMilliseconds: 90_000, title: "Closing"),
            PodcastChapter(startMilliseconds: 100_000, title: "At the end"),
            PodcastChapter(startMilliseconds: 103_000, title: "Past the end, within the margin"),
        ]).bookChapters(fileDuration: 100)

        XCTAssertEqual(chapters.map(\.title), ["Interview", "Chapter 2", "Closing"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 60, 90])
        XCTAssertEqual(chapters.map(\.duration), [60, 30, 10])
    }

    /// One chapter is a book of one chapter that lasts the whole file.
    func testOneChapterLastsTheWholeFile() {
        let chapters = bookChapters(starting: [0], fileDuration: 61.5)

        XCTAssertEqual(chapters.map(\.title), ["One"])
        XCTAssertEqual(chapters.map(\.startTime), [0])
        XCTAssertEqual(chapters.map(\.duration), [61.5])
    }

    /// The most chapters a file may hold are all taken, each beginning where
    /// it says, and together they last exactly as long as the audio.
    func testTheMostChaptersAFileMayHoldAreAllTaken() {
        let count = PodcastChapters.maximumChapters
        let starts = (0..<count).map { TimeInterval($0) * 2 }

        let chapters = bookChapters(starting: starts, fileDuration: TimeInterval(count) * 2)

        XCTAssertEqual(chapters.count, count)
        XCTAssertEqual(chapters.map(\.startTime), starts)
        XCTAssertEqual(chapters.map(\.duration), Array(repeating: 2, count: count))
    }

    /// A title of a megabyte reaches a heading no longer than the limit,
    /// with a mark that it was cut; a title at the limit is kept whole.
    func testAVeryLongTitleIsCutToTheLimit() {
        let limit = PodcastChapters.maximumTitleCharacters
        XCTAssertEqual(limit, 200)
        let atTheLimit = String(repeating: "a", count: limit)
        let huge = String(repeating: "word ", count: 200_000)

        XCTAssertEqual(PodcastChapters.headingTitle(atTheLimit), atTheLimit)
        XCTAssertEqual(PodcastChapters.headingTitle(atTheLimit + "a"), atTheLimit + "\u{2026}")
        // The limit falls just after a space, which is not kept before the
        // mark: it would be heard as a pause.
        let cut = PodcastChapters.headingTitle(huge)
        XCTAssertEqual(cut, String(huge.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}")
        XCTAssertLessThanOrEqual(cut.unicodeScalars.count, limit + 1)
        XCTAssertFalse(cut.hasSuffix(" \u{2026}"))

        // Through the whole path: the title is what a book names its chapter.
        let chapters = PodcastChapters(chapters: [PodcastChapter(startMilliseconds: 0, title: huge)])
            .bookChapters(fileDuration: 10)
        XCTAssertEqual(chapters.map(\.title), [cut])
    }

    /// Characters the listener sees as one are never parted by the cut: an
    /// accented letter, an emoji joined from several, and a flag stay whole
    /// or go; and one character of a megabyte of marks is no title.
    func testTheCutKeepsWholeCharactersAndBoundsOneEndlessCharacter() {
        let limit = PodcastChapters.maximumTitleCharacters
        // "é" as e and a combining acute: two scalars, one character. After
        // one plain letter, 99 of them fill 199 scalars and a hundredth would
        // pass the limit; a cut by scalars would keep its "e" without its accent.
        let accented = "a" + String(repeating: "e\u{301}", count: limit)
        XCTAssertEqual(
            PodcastChapters.headingTitle(accented),
            "a" + String(repeating: "e\u{301}", count: (limit - 1) / 2) + "\u{2026}"
        )

        // A family emoji is seven scalars; one that would straddle the limit goes whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let padded = String(repeating: "a", count: limit - 3) + family
        XCTAssertEqual(PodcastChapters.headingTitle(padded), String(repeating: "a", count: limit - 3) + "\u{2026}")

        // One letter followed by a megabyte of combining marks is a single
        // character that cannot fit: nothing of it is kept, so the book names the chapter by its place.
        let endless = "a" + String(repeating: "\u{301}", count: 1_000_000)
        XCTAssertEqual(PodcastChapters.headingTitle(endless), "")
        XCTAssertEqual(
            PodcastChapters(chapters: [PodcastChapter(startMilliseconds: 0, title: endless)]).bookChapters(fileDuration: 5).map(\.title),
            ["Chapter 1"]
        )
    }

    /// A control character is dropped from a title, a title nobody can see
    /// or hear is no title, and an ordinary title is untouched: Markdown's
    /// characters, a joiner in an emoji, and a right-to-left mark included.
    func testTitlesLoseControlCharactersAndInvisibleOnesAreUntitled() {
        XCTAssertEqual(PodcastChapters.headingTitle("Tide\u{0}table\u{7}"), "Tidetable")
        for invisible in ["", " ", "\u{200B}", "\u{FEFF}\u{200B}\u{2060}", "\u{0}", "\u{0}\u{200D}\u{200E}"] {
            XCTAssertEqual(PodcastChapters.headingTitle(invisible), "", "\(invisible.unicodeScalars.map(\.value))")
        }
        for plain in ["# Not a heading", "*stars* and _bars_", "Q&A --> Part 2", "<b>bold</b>", "\u{1F468}\u{200D}\u{1F469}", "שלום\u{200F}"] {
            XCTAssertEqual(PodcastChapters.headingTitle(plain), plain)
        }
    }

    /// A line feed and a run of white space in a title are finished by the
    /// reader into single spaces before the title reaches a heading.
    func testALineFeedInAFilesTitleIsOneLineInTheBook() throws {
        let file = Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Line one\nline\ttwo   end"}]}"#.utf8)

        let chapters = try PodcastChapters.read(file).bookChapters(fileDuration: 10)

        XCTAssertEqual(chapters.map(\.title), ["Line one line two end"])
    }

    // MARK: - The Analysis

    /// An episode's chapters kept beside its audio become its chapters and
    /// headings when its audio is indexed, and the index made of them is
    /// trusted when the book is read again; nothing is logged about them.
    func testKeptChaptersBecomeTheEpisodesHeadingsWhenItsAudioIsIndexed() throws {
        let world = try makeIntegrationWorld("Podcast Chapters")
        let title = uniqueTitle("Four Tones")
        let book = try makeSilentEpisode(in: world, title: title, duration: 4, keeping: sampleChaptersFile())

        let analysis = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(analysis.usedPersistedIndex, "the index the import saved was set aside")
        XCTAssertEqual(analysis.index.allHeadings.map(\.text), Self.sampleTitles)
        XCTAssertEqual(analysis.content.chapters.map(\.title), Self.sampleTitles)
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "), [])
    }

    /// A kept file that is not a chapters file leaves the episode one
    /// chapter, and the debug log says why, naming the book.
    func testAKeptFileThatIsNotChaptersLeavesOneChapterAndSaysWhy() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Unreadable")
        let title = uniqueTitle("Ferry Bulletin")
        let book = try makeSilentEpisode(in: world, title: title, duration: 2, keeping: Data("{\"chapters\": [".utf8))

        XCTAssertEqual(try indexedHeadings(of: book), [title])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "),
            ["PODCAST_CHAPTERS_UNUSED: \(title): not a chapters file"]
        )
    }

    /// A kept file that cannot be read leaves the episode one chapter, and
    /// the debug log says why, naming the error by its code and domain.
    func testAKeptFileThatCannotBeReadLeavesOneChapterAndSaysWhy() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Unreadable File")
        let title = uniqueTitle("Ferry Bulletin")
        let chapters = try sampleChaptersFile()

        let book = try world.makeOneFileAudioBook(title: title, fileName: "\(title).wav") { file in
            try AudioTestFixtures.writeSilence(to: file, duration: 2)
            let kept = TextMouthPaths.podcastChaptersPath(in: file.deletingLastPathComponent())
            try chapters.write(to: kept)
            // No one may read the file; its folder, still writable, lets the
            // world's tear-down remove it.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: kept.path)
        }
        let kept = TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        }
        let failure = try XCTUnwrap(thrownError(by: { _ = try FileHandle(forReadingFrom: kept) }))

        XCTAssertEqual(try indexedHeadings(of: book), [title])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "),
            ["PODCAST_CHAPTERS_UNUSED: \(title): the file could not be read: \(loggedName(of: failure))"]
        )
    }

    /// A kept file larger than 1 MB is refused, though it holds chapters
    /// that fit: the episode is one chapter, and the log says why. A file
    /// of exactly 1 MB is read.
    func testAKeptFileLargerThanTheLimitIsRefused() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Too Large")
        let chapters = try sampleChaptersFile()
        let limit = TimedTextLimits.podcastChaptersBytes
        let tooLarge = uniqueTitle("Tide Report")
        let atTheLimit = uniqueTitle("Tide Report")

        let refused = try makeSilentEpisode(in: world, title: tooLarge, duration: 4, keeping: padded(chapters, to: limit + 1))
        let read = try makeSilentEpisode(in: world, title: atTheLimit, duration: 4, keeping: padded(chapters, to: limit))

        XCTAssertEqual(try indexedHeadings(of: refused), [tooLarge])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(tooLarge): "),
            ["PODCAST_CHAPTERS_UNUSED: \(tooLarge): the file is larger than the 1 MB TextMouth reads"]
        )
        XCTAssertEqual(try indexedHeadings(of: read), Self.sampleTitles)
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(atTheLimit): "), [])
    }

    /// Kept chapters whose last begins more than 5 seconds past the end of
    /// the audio were made for another edition of the episode: it is one
    /// chapter, and the log says why.
    func testKeptChaptersThatDoNotFitTheAudioLeaveOneChapterAndSaySo() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Past the End")
        let title = uniqueTitle("Four Tones")
        let book = try makeSilentEpisode(
            in: world, title: title, duration: 4, keeping: twoChapters(lastBeginningAt: 60_000).normalizedJSON()
        )

        XCTAssertEqual(try indexedHeadings(of: book), [title])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "),
            ["PODCAST_CHAPTERS_UNUSED: \(title): its last chapter begins past the end of the audio"]
        )
    }

    /// An episode whose audio has chapters of its own keeps them; the
    /// podcast's chapters kept beside it go unused, and the log says why.
    func testAnEpisodeWithChaptersOfItsOwnKeepsThemAndSaysWhy() async throws {
        let world = try makeIntegrationWorld("Podcast Chapters Own")
        let chaptered = try makeSandboxDirectory("PodcastChaptersAudio").appendingPathComponent("Chaptered.m4a")
        try await AudioTestFixtures.writeChapteredAAC(to: chaptered, duration: 3, chapters: Self.ownMarkers)
        let title = uniqueTitle("Harbor Lectures")

        let book = try makeEpisode(in: world, title: title, fileName: "\(title).m4a", keeping: sampleChaptersFile()) { file in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: chaptered, to: file)
        }

        XCTAssertEqual(try indexedHeadings(of: book), ["Harbor Approach", "Breakwater Survey"])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "),
            ["PODCAST_CHAPTERS_UNUSED: \(title): the audio has chapters of its own"]
        )
    }

    /// An analysis told not to read the podcast's chapters leaves the episode
    /// one chapter though they are kept beside its audio and fit it, and says
    /// nothing; the same analysis not told takes them. An edit of the audio
    /// asks for the first, since the chapters it could not remove were timed
    /// to the audio as it was.
    func testAnAnalysisToldNotToReadThePodcastsChaptersLeavesTheEpisodeOneChapter() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Not Read")
        let title = uniqueTitle("Four Tones")
        let book = try makeSilentEpisode(in: world, title: title, duration: 4, keeping: sampleChaptersFile())

        let skipped = try BookContentAnalysisService.analyzeAudio(
            book: book, url: book.bookFileURL, readingPodcastChapters: false
        )
        XCTAssertEqual(skipped.index.allHeadings.map(\.text), [title])
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "), [])

        let read = try BookContentAnalysisService.analyzeAudio(book: book, url: book.bookFileURL)
        XCTAssertEqual(read.index.allHeadings.map(\.text), Self.sampleTitles)
    }

    /// A folder of tracks takes no chapters, whatever its package holds,
    /// since each track is its own chapter; and nothing is logged about a
    /// file that was never looked at.
    func testAFolderOfTracksTakesNoKeptChapters() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Folder")
        let title = uniqueTitle("Two Tracks")
        let chapters = try sampleChaptersFile()
        let book = try world.makeOneFileAudioBook(title: title, fileName: "Tracks") { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["01 First.wav", "02 Second.wav"] {
                try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(name), duration: 2)
            }
            try chapters.write(to: TextMouthPaths.podcastChaptersPath(in: folder.deletingLastPathComponent()))
        }

        // One heading for each track, none of the podcast's four.
        let headings = try indexedHeadings(of: book)
        XCTAssertEqual(headings.count, 2)
        XCTAssertTrue(Set(headings).isDisjoint(with: Self.sampleTitles), "\(headings)")
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "), [])
    }

    /// With the transcript of an episode that has podcast chapters, the
    /// transcript's text has a heading for each chapter, titled as the
    /// chapter is even when the title holds what Markdown or the chapter
    /// marker is made of, and each sentence is in the chapter it was heard
    /// in, timed from that chapter's start, so following along crosses from
    /// one chapter to the next.
    func testATranscriptsHeadingsFollowThePodcastsChapters() throws {
        let world = try makeIntegrationWorld("Podcast Chapters Transcript")
        let titles = ["Q&A --> Part <b>2</b>", "# Hash and *stars*", "Plain"]
        let chapters = try PodcastChapters(chapters: zip([0, 2_000, 4_000], titles).map {
            PodcastChapter(startMilliseconds: $0, title: $1)
        }).normalizedJSON()
        let book = try makeSilentEpisode(in: world, title: uniqueTitle("Three Parts"), duration: 6, keeping: chapters)
        let audio = try BookContentAnalysisService.load(book: book).index
        XCTAssertEqual(audio.allHeadings.map(\.text), titles)
        let fileName = book.bookFileURL.lastPathComponent
        let transcript = TranscriptFixtures.transcript([(path: fileName, duration: 6_000, sentences: [
            TranscriptFixtures.sentence("The first part opens.", from: 500, to: 1_500),
            TranscriptFixtures.sentence("The second part follows.", from: 2_500, to: 3_500),
            TranscriptFixtures.sentence("The last part closes.", from: 4_500, to: 5_500),
        ])])

        let parts = TranscriptTextBuilder.chapters(of: transcript, over: audio, bookFileName: fileName)
        XCTAssertEqual(parts.map(\.title), titles)
        XCTAssertEqual(parts.map { $0.sentences.map(\.text) }, [
            ["The first part opens."], ["The second part follows."], ["The last part closes."],
        ])
        // Each is timed from its own chapter's start.
        XCTAssertEqual(parts.map { $0.sentences.map(\.startMilliseconds) }, [[500], [500], [500]])

        let text = try XCTUnwrap(TranscriptTextBuilder.text(of: parts, bookTitle: book.title, bookAuthor: book.author))
        XCTAssertEqual(text.chapters.map(\.title), titles)
        XCTAssertEqual(text.chapters.map { $0.headings.map(\.text) }, titles.map { [$0] })
        XCTAssertEqual(text.sentences.map(\.count), [1, 1, 1])
        XCTAssertNil(text.readingIndex.alignmentFailure(with: text.chapters))
    }

    /// A book without a package of its own, as only the earliest books
    /// are, takes no chapters from the folder its file lies in, which is
    /// where its package would be.
    func testABookWithoutAPackageOfItsOwnTakesNoKeptChapters() throws {
        let folderPath = "Podcast Chapters \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Four Tones.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 4)
        try sampleChaptersFile().write(to: TextMouthPaths.podcastChaptersPath(in: folder))
        let book = Book(title: "Four Tones", format: .audio, filePath: file.path, md5Hash: UUID().uuidString, folderPath: folderPath)
        // The chapters lie where the book's package would keep them, so only
        // the check for a package of its own keeps the analysis from them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path))

        let analysis = try BookContentAnalysisService.analyzeAudio(book: book, url: file)

        XCTAssertEqual(analysis.index.allHeadings.map(\.text), ["Four Tones"])
    }

    // MARK: - The Episode's Download Deleted

    /// Deleting an episode's download, its package kept, removes the
    /// chapters kept beside the audio with it, and keeps the record and the
    /// transcript, which are the listener's.
    func testDeletingAnEpisodesDownloadRemovesItsChaptersAndKeepsItsTranscript() throws {
        let package = try makeSandboxDirectory("PodcastChaptersEpisode")
            .appendingPathComponent("Episode.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let names = [
            "Episode.mp3", TextMouthPaths.bookInfoFileName, TextMouthPaths.transcriptFileName,
            TextMouthPaths.podcastChaptersFileName,
        ]
        for name in names {
            try Data("{}".utf8).write(to: package.appendingPathComponent(name))
        }
        let row = Book(
            title: "Episode",
            format: .audio,
            filePath: package.appendingPathComponent("Episode.mp3").path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: package.lastPathComponent
        )

        FeedItemPackage.removeWhatTheFileMade(of: row, from: package)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: package.path).sorted(),
            [TextMouthPaths.bookInfoFileName, TextMouthPaths.transcriptFileName]
        )
    }

    // MARK: - An Edit of the Audio

    /// Saving an edit of an episode's audio sets the chapters kept beside
    /// it aside, hidden, before the edited audio is analyzed, since they
    /// were timed to the audio before the edit: the episode is one chapter
    /// after the save, though its chapters would still fit, and the log says
    /// why.
    func testSavingAnEditOfTheAudioSetsTheKeptChaptersAside() async throws {
        let world = try makeIntegrationWorld("Podcast Chapters Edit")
        let title = uniqueTitle("Canal Survey")
        let chapters = try PodcastChapters(chapters: [
            PodcastChapter(startMilliseconds: 0, title: "Locks"),
            PodcastChapter(startMilliseconds: 4_000, title: "Weirs"),
            PodcastChapter(startMilliseconds: 8_000, title: "Towpaths"),
        ]).normalizedJSON()
        // Ten seconds of the identity ramp the audio editor's save tests
        // write, at 8,000 frames a second.
        let book = try makeEpisode(in: world, title: title, fileName: "\(title).wav", keeping: chapters) { file in
            try AudioTestFixtures.writeIdentityRamp(to: file, frames: 80_000, sampleRate: 8_000)
        }
        addTeardownBlock {
            AudioEditScratch.remove(for: book.id)
            ReadingTextCache.shared.remove(bookID: book.id)
        }
        XCTAssertEqual(try indexedHeadings(of: book), ["Locks", "Weirs", "Towpaths"])

        let session = try await AudioEditSession.open(bookID: book.id, in: world.library)
        defer { session.close() }
        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))
        let outcome = try await session.save()
        // The record the save wrote, with the index made of the edited audio.
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(outcome.rendered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersSetAsidePath(in: book.tmbDirectory).path),
            "the chapters were deleted, not set aside"
        )
        let saved = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(try indexedHeadings(of: saved), [title])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_SET_ASIDE: \(title): "),
            ["PODCAST_CHAPTERS_SET_ASIDE: \(title): the audio was edited, so the podcast's chapters no longer fit it"]
        )
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "), [])
    }

    /// Reverting an edited episode to its original take, and saving, brings
    /// the podcast's chapters back with the original audio: the episode is
    /// its three chapters again after the revert as it was before the edit,
    /// and the log says so. A second edit sets them aside again, and undoing
    /// it brings them back again. An episode that was never edited keeps
    /// its chapters, and nothing is said.
    func testRevertingAnEditedEpisodeBringsItsChaptersBack() async throws {
        let world = try makeIntegrationWorld("Podcast Chapters Revert")
        let title = uniqueTitle("Canal Survey")
        let chapters = try PodcastChapters(chapters: [
            PodcastChapter(startMilliseconds: 0, title: "Locks"),
            PodcastChapter(startMilliseconds: 4_000, title: "Weirs"),
            PodcastChapter(startMilliseconds: 8_000, title: "Towpaths"),
        ]).normalizedJSON()
        let book = try makeEpisode(in: world, title: title, fileName: "\(title).wav", keeping: chapters) { file in
            try AudioTestFixtures.writeIdentityRamp(to: file, frames: 80_000, sampleRate: 8_000)
        }
        addTeardownBlock {
            AudioEditScratch.remove(for: book.id)
            ReadingTextCache.shared.remove(bookID: book.id)
        }
        let live = TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory)
        let aside = TextMouthPaths.podcastChaptersSetAsidePath(in: book.tmbDirectory)
        let original = ["Locks", "Weirs", "Towpaths"]
        XCTAssertEqual(try indexedHeadings(of: book), original)

        // Edited and saved: the chapters are set aside.
        let session = try await AudioEditSession.open(bookID: book.id, in: world.library)
        defer { session.close() }
        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))
        XCTAssertTrue(try await session.save().rendered)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedHeadings(of: try XCTUnwrap(world.library.bookByID(book.id))), [title])
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))

        // Every edit undone and saved: the chapters are back.
        while try await session.undo() != nil {}
        XCTAssertTrue(try await session.save().rendered, "the reverted audio was not saved")
        LibraryPersistenceService.flushPendingSave()
        let reverted = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(try indexedHeadings(of: reverted), original, "reverting to the original lost the podcast's chapters")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path), "the set-aside copy was left behind")
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_RESTORED: \(title): "),
            ["PODCAST_CHAPTERS_RESTORED: \(title): every edit was undone, so the podcast's chapters fit the audio again"]
        )

        // Edited again: set aside again.
        try await session.perform(.cut(AudioTimeRange(start: 3, end: 4)))
        XCTAssertTrue(try await session.save().rendered)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedHeadings(of: try XCTUnwrap(world.library.bookByID(book.id))), [title])
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
    }

    /// Chapters that could not be set aside after an edit are not laid over the
    /// edited audio all the same: the save's analysis does not read them, so
    /// the episode is one chapter, the log says the file was left, and the
    /// save has gone on. (The file is made undeletable with the immutable flag.)
    func testChaptersThatCannotBeSetAsideAreNotLaidOverTheEditedAudio() async throws {
        let world = try makeIntegrationWorld("Podcast Chapters Edit Left")
        let title = uniqueTitle("Canal Survey")
        let chapters = try PodcastChapters(chapters: [
            PodcastChapter(startMilliseconds: 0, title: "Locks"),
            PodcastChapter(startMilliseconds: 4_000, title: "Weirs"),
            PodcastChapter(startMilliseconds: 8_000, title: "Towpaths"),
        ]).normalizedJSON()
        let book = try makeEpisode(in: world, title: title, fileName: "\(title).wav", keeping: chapters) { file in
            try AudioTestFixtures.writeIdentityRamp(to: file, frames: 80_000, sampleRate: 8_000)
        }
        addTeardownBlock {
            AudioEditScratch.remove(for: book.id)
            ReadingTextCache.shared.remove(bookID: book.id)
        }
        XCTAssertEqual(try indexedHeadings(of: book), ["Locks", "Weirs", "Towpaths"])
        let kept = TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: kept.path)
        // Lifted before the world's tear-down removes the package.
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: kept.path)
        }
        let aside = TextMouthPaths.podcastChaptersSetAsidePath(in: book.tmbDirectory)
        let failure = try XCTUnwrap(thrownError(by: { try FileManager.default.moveItem(at: kept, to: aside) }))

        let session = try await AudioEditSession.open(bookID: book.id, in: world.library)
        defer { session.close() }
        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))
        let outcome = try await session.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(outcome.rendered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        let saved = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(try indexedHeadings(of: saved), [title])
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_LEFT: \(title): "),
            [
                "PODCAST_CHAPTERS_LEFT: \(title): the audio was edited, but the podcast's chapters could not be set aside: "
                    + loggedName(of: failure),
            ]
        )
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_UNUSED: \(title): "), [])
    }

    /// Setting aside, or bringing back, the chapters of a package that
    /// keeps none is no error, and says nothing.
    func testSettingAsideChaptersThatAreNotThereSaysNothing() throws {
        let package = try makeSandboxDirectory("PodcastChaptersNone")
        let title = uniqueTitle("Canal Survey")
        let book = Book(title: title, format: .audio, filePath: package.appendingPathComponent("\(title).wav").path, md5Hash: UUID().uuidString)

        LibraryViewModel.setAsidePodcastChapters(of: book, in: package)
        LibraryViewModel.restorePodcastChapters(of: book, in: package)

        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_SET_ASIDE: \(title): "), [])
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_RESTORED: \(title): "), [])
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_LEFT: \(title): "), [])
    }

    /// Chapters set aside come back only to an empty place: a package that
    /// holds chapters of its own again, as a new download's, keeps them, and
    /// the set-aside copy stays as it is; and chapters set aside over an
    /// older set-aside copy replace it.
    func testSetAsideChaptersNeverReplaceChaptersInTheirPlace() throws {
        let package = try makeSandboxDirectory("PodcastChaptersTwoCopies")
        let live = TextMouthPaths.podcastChaptersPath(in: package)
        let aside = TextMouthPaths.podcastChaptersSetAsidePath(in: package)
        let title = uniqueTitle("Canal Survey")
        let book = Book(title: title, format: .audio, filePath: package.appendingPathComponent("\(title).wav").path, md5Hash: UUID().uuidString)
        try Data("older".utf8).write(to: aside)
        try Data("newer".utf8).write(to: live)

        LibraryViewModel.restorePodcastChapters(of: book, in: package)

        XCTAssertEqual(try Data(contentsOf: live), Data("newer".utf8), "chapters in their place were replaced")
        XCTAssertEqual(try Data(contentsOf: aside), Data("older".utf8))
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_RESTORED: \(title): "), [])

        LibraryViewModel.setAsidePodcastChapters(of: book, in: package)

        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertEqual(try Data(contentsOf: aside), Data("newer".utf8), "the older set-aside copy was kept over the newer")

        LibraryViewModel.restorePodcastChapters(of: book, in: package)

        XCTAssertEqual(try Data(contentsOf: live), Data("newer".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    /// Chapters that cannot be set aside after an edit stay, with one line
    /// saying so, which names the error by its code and domain, and the
    /// save goes on.
    func testChaptersThatCannotBeSetAsideAreLeftWithALine() throws {
        let package = try makeSandboxDirectory("PodcastChaptersLocked")
        let kept = TextMouthPaths.podcastChaptersPath(in: package)
        try sampleChaptersFile().write(to: kept)
        // A folder whose files cannot be removed: put back before the
        // folder is removed, as tear-down blocks run in reverse.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
        }
        let failure = try XCTUnwrap(thrownError(by: {
            try FileManager.default.moveItem(at: kept, to: TextMouthPaths.podcastChaptersSetAsidePath(in: package))
        }))
        let title = uniqueTitle("Canal Survey")
        let book = Book(title: title, format: .audio, filePath: package.appendingPathComponent("\(title).wav").path, md5Hash: UUID().uuidString)

        LibraryViewModel.setAsidePodcastChapters(of: book, in: package)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(
            loggedLines(from: "PODCAST_CHAPTERS_LEFT: \(title): "),
            [
                "PODCAST_CHAPTERS_LEFT: \(title): the audio was edited, but the podcast's chapters could not be set aside: "
                    + loggedName(of: failure),
            ]
        )
        XCTAssertEqual(loggedLines(from: "PODCAST_CHAPTERS_SET_ASIDE: \(title): "), [])
    }
}
