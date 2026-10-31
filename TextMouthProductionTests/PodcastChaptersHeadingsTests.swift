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
}
