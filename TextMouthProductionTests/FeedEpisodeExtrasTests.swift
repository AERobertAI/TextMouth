import Combine
import XCTest
@testable import TextMouth

/// A podcast episode's own transcript and chapters, fetched with its download
/// (FMT25, `FeedEpisodeExtras`): which links are fetched and in what order,
/// what the episode gets from them, what happens when they fail, and that
/// nothing about them can stop the episode's own download.
///
/// Each end-to-end test runs a real download through a feed engine of its own
/// and a stub server, which every request reaches and none leaves. The
/// episode's title is made unique, since every test of the run writes to the
/// same debug log, so each test reads only its own lines.
@MainActor
final class FeedEpisodeExtrasTests: XCTestCase {
    /// The titles of the chapters sample (`podcast-chapters-json/chapters.json`)
    /// left once its `toc: false` chapter is out, in order.
    private static let sampleChapterTitles = ["Intro — 440 Hz", "Second: café", "Third, with a place", "Outro"]

    /// The sentences the WebVTT sample (`vtt/tone4.vtt`) makes, each voice
    /// named when it changes.
    private static let sampleSentences = [
        "Ana: First tone, 440 hertz.",
        "Ben: Second tone, 550 hertz & bold.",
        "Ana: Third tone, café 660 hertz. Second line of the cue.",
        "The fourth, 880 hertz, with no speaker.",
    ]

    // MARK: - Choosing the Transcript

    /// A link's format comes from its type, in any letter case and with any
    /// parameters; a type TextMouth does not know, or none, leaves it to the
    /// address's extension; HTML and plain text carry no times, and are
    /// never fetched, whatever their address says.
    func testATranscriptsFormatIsKnownByItsTypeAndThenItsAddress() throws {
        let cases: [(type: String?, address: String, format: TimedTextFormat?)] = [
            ("text/vtt", "https://a.example/t", .webVTT),
            ("TEXT/VTT", "https://a.example/t", .webVTT),
            ("text/vtt; charset=utf-8", "https://a.example/t", .webVTT),
            (" Text/VTT ; charset=utf-8", "https://a.example/t", .webVTT),
            ("application/json", "https://a.example/t", .podcastJSON),
            ("application/json;charset=utf-8", "https://a.example/t", .podcastJSON),
            ("application/x-subrip", "https://a.example/t", .subRip),
            ("application/srt", "https://a.example/t", .subRip),
            ("application/x-srt", "https://a.example/t", .subRip),
            ("text/srt", "https://a.example/t", .subRip),
            ("text/x-srt", "https://a.example/t", .subRip),
            // The type decides over the address.
            ("text/vtt", "https://a.example/t.srt", .webVTT),
            // No times: never fetched, whatever the address says.
            ("text/html", "https://a.example/t.vtt", nil),
            ("TEXT/PLAIN; charset=utf-8", "https://a.example/t.srt", nil),
            // No type, or one TextMouth does not know: the address decides.
            (nil, "https://a.example/t.vtt", .webVTT),
            (nil, "https://a.example/t.VTT", .webVTT),
            (nil, "https://a.example/t.json", .podcastJSON),
            (nil, "https://a.example/t.SRT", .subRip),
            ("application/octet-stream", "https://a.example/t.vtt", .webVTT),
            (nil, "https://a.example/t.vtt?token=1", .webVTT),
            (nil, "https://a.example/t.txt", nil),
            (nil, "https://a.example/t", nil),
            ("application/pdf", "https://a.example/t", nil),
        ]
        for (type, address, format) in cases {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(
                FeedEpisodeExtras.transcriptFormat(of: FeedResource(url: url, mimeType: type)),
                format,
                "\(type ?? "no type") at \(address)"
            )
        }
    }

    /// An episode's links are tried WebVTT first, then JSON, then SubRip,
    /// each format's in the feed's order, each address once, and at most
    /// three; HTML and text are never among them.
    func testAnEpisodesTranscriptLinksAreTriedInOrderEachOnceAndAtMostThree() throws {
        func resource(_ path: String, _ type: String?) throws -> FeedResource {
            FeedResource(url: try XCTUnwrap(URL(string: "https://a.example\(path)")), mimeType: type)
        }
        func paths(of resources: [FeedResource]) -> [String] {
            let item = FeedItem(id: "guid:1", title: "An episode", firstSeen: Date(), transcripts: resources)
            return FeedEpisodeExtras.transcriptCandidates(of: item).map { "\($0.format.rawValue) \($0.url.path)" }
        }

        XCTAssertEqual(try paths(of: [
            resource("/a.srt", "application/x-subrip"),
            resource("/b.html", "text/html"),
            resource("/c.json", "application/json"),
            resource("/d.txt", "text/plain"),
            resource("/e.vtt", "text/vtt"),
        ]), ["webvtt /e.vtt", "podcast-json /c.json", "srt /a.srt"])

        // Each format's links keep the feed's order.
        XCTAssertEqual(try paths(of: [
            resource("/2.vtt", "text/vtt"),
            resource("/1.vtt", "text/vtt"),
        ]), ["webvtt /2.vtt", "webvtt /1.vtt"])

        // An address listed again is tried once, under the format tried first.
        XCTAssertEqual(try paths(of: [
            resource("/same", "application/x-subrip"),
            resource("/same", "text/vtt"),
            resource("/same", "text/vtt"),
        ]), ["webvtt /same"])

        // No more than three, however many are listed, the most preferred kept.
        XCTAssertEqual(try paths(of: [
            resource("/s.srt", "application/x-subrip"),
            resource("/1.vtt", "text/vtt"),
            resource("/2.vtt", "text/vtt"),
            resource("/3.vtt", "text/vtt"),
            resource("/4.vtt", "text/vtt"),
        ]), ["webvtt /1.vtt", "webvtt /2.vtt", "webvtt /3.vtt"])
        XCTAssertEqual(FeedEpisodeExtras.maximumTranscriptTries, 3)

        XCTAssertEqual(paths(of: []), [])
        let none = FeedItem(id: "guid:1", title: "An episode", firstSeen: Date())
        XCTAssertTrue(FeedEpisodeExtras.transcriptCandidates(of: none).isEmpty)
    }

    /// The limits the charter gives (decision 5), and the limit on the whole.
    func testTheLimitsAreTheOnesAgreed() {
        XCTAssertEqual(TimedTextLimits.podcastTranscriptBytes, 5 * 1_048_576)
        XCTAssertEqual(TimedTextLimits.podcastChaptersBytes, 1_048_576)
        XCTAssertEqual(FeedEpisodeExtras.timeLimit, .seconds(120))
    }

    // MARK: - An Episode With Both

    /// The whole of it: a download fetches the episode's chapters and its
    /// transcript. The book's package holds the chapters, which are its
    /// headings; its transcript records that it is the podcast's own, in its
    /// format, with no file's name, and holds the file's words and times; the
    /// row says it is transcribed; each of the four files is asked for once,
    /// no address inside a file is opened, and the debug log has one line
    /// for each step, holding neither a word of the transcript nor an
    /// address.
    func testAnEpisodeDownloadsWithItsOwnTranscriptAndChapters() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasBoth")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        // The chapters file names a link and a picture at example.invalid,
        // where nothing records a request: moved to the stub server, a request
        // for either would show among the requests below.
        var chapters = try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json+chapters")
        chapters.body = Data(String(decoding: chapters.body, as: UTF8.self)
            .replacingOccurrences(of: "example.invalid", with: world.server.host).utf8)
        XCTAssertTrue(String(decoding: chapters.body, as: UTF8.self).contains("https://\(world.server.host)/art.jpg"))
        world.server.serve("/c.json", chapters)
        let wordsBefore = debugLogLines(containing: "First tone").count

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        // The chapters, kept beside the audio and read as its headings.
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path))
        let analysis = try BookContentAnalysisService.load(book: book)
        XCTAssertEqual(analysis.index.allHeadings.map(\.text), Self.sampleChapterTitles)
        XCTAssertEqual(analysis.content.chapters.map(\.title), Self.sampleChapterTitles)

        // The transcript, the podcast's own.
        let transcript = try foundTranscript(of: book)
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .podcast, format: .webVTT))
        XCTAssertNil(transcript.source?.fileName, "a podcast's transcript named a file")
        XCTAssertEqual(transcript.locale, OutsideTranscript.undeterminedLocale)
        let file = try XCTUnwrap(transcript.files.first)
        XCTAssertEqual(transcript.files.count, 1)
        XCTAssertEqual(file.path, book.bookFileURL.lastPathComponent)
        XCTAssertEqual(file.sentences.map(\.text), Self.sampleSentences)
        XCTAssertEqual(file.sentences.map(\.startMilliseconds), [0, 1_000, 2_000, 3_000])
        XCTAssertEqual(file.sentences.map(\.endMilliseconds), [900, 1_900, 2_900, 3_900])

        // Its text is written, and the row says so.
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory).path))
        XCTAssertTrue(TranscribedBooks.shared.contains(book.id), "the row does not say the episode is transcribed")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.transcript?.source, transcript.source)

        // Each file once; nothing a file names is opened.
        XCTAssertEqual(Set(world.server.requests.compactMap { $0.url?.path }), ["/audio/1.m4a", "/c.json", "/feed.xml", "/t.vtt"])
        for path in ["/audio/1.m4a", "/c.json", "/t.vtt"] {
            XCTAssertEqual(world.server.requests(to: path).count, 1, "\(path) was not asked for once")
        }

        // One line for each step, naming the episode and its feed.
        let episode = "\(title) (The Tactile Atlas)"
        XCTAssertEqual(debugLogLines(containing: "FEED_CHAPTERS_FETCHED: \(episode): 4 chapters").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_FETCHED: \(episode): WebVTT, 4 passages").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_ATTACHED: \(episode): WebVTT, ").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_CHAPTERS_REFUSED: \(episode)").count, 0)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(episode)").count, 0)
        XCTAssertEqual(debugLogLines(containing: "FEED_EPISODE_FILES_TIMED_OUT: \(episode)").count, 0)
        XCTAssertEqual(debugLogLines(containing: "First tone").count, wordsBefore, "a transcript's words reached the log")
        for path in ["/t.vtt", "/c.json"] {
            XCTAssertEqual(debugLogLines(containing: world.server.url(path).absoluteString), [], "an address reached the log")
        }
    }

    /// An episode linking nothing downloads as it always did: nothing else
    /// is asked for, no file is kept beside it, no transcript is made, and
    /// the log says nothing of them.
    func testAnEpisodeLinkingNothingAsksForNothingMore() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasNothing")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [], chapters: nil)
        try serveAudio(in: world, duration: 1)

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(Set(world.server.requests.compactMap { $0.url?.path }), ["/audio/1.m4a", "/feed.xml"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path))
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        XCTAssertEqual(debugLogLines(containing: "(The Tactile Atlas): ").filter { $0.contains(title) && $0.contains("TRANSCRIPT") }, [])
    }

    // MARK: - Files That Fail

    /// A transcript and a chapters file that both answer "not found" leave
    /// the episode as it would have been: one chapter, no transcript, no
    /// failure, and a line for each saying why, naming its server by its host.
    func testFilesNotFoundLeaveTheEpisodeAsItIs() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtras404")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        try serveAudio(in: world, duration: 1)
        world.server.serve("/t.vtt", StubResponse(status: 404))
        world.server.serve("/c.json", StubResponse(status: 404))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(try BookContentAnalysisService.load(book: book).content.chapters.count, 1)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        XCTAssertFalse(TranscribedBooks.shared.contains(book.id))
        let episode = "\(title) (The Tactile Atlas)"
        let host = world.server.host
        XCTAssertEqual(debugLogLines(containing: "FEED_CHAPTERS_REFUSED: \(episode): from \(host): not found (404)").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(episode): WebVTT from \(host): not found (404)").count, 1)
    }

    /// A failure of any other kind says so in plain words too: a server's
    /// error, a server that cannot be found, a password, a file gone, and a
    /// connection that fails, none of which names an address.
    func testEachFailureOfAFetchIsWordedForTheLog() {
        let limit = 5 * 1_048_576
        let host = "cdn.example"
        let cases: [(FeedFetchError, String)] = [
            (.notFound, "not found (404)"),
            (.serverError(status: 500, host: host), "the server answered with error 500"),
            (.tooLarge(host: host), "larger than the 5120 KB TextMouth fetches"),
            (.timedOut(host: host), "timed out"),
            (.offline, "offline"),
            (.needsPassword, "it needs a password"),
            (.gone, "gone (410)"),
            (.constrainedNetwork, "refused on a network with data limits"),
            (.notAWebAddress, "not a web address"),
            (.hostNotFound(host: host), "the connection failed"),
            (.connectionFailed(host: host, reason: "https://cdn.example/secret?token=1"), "the connection failed"),
            (.cancelled, "stopped"),
        ]
        for (error, words) in cases {
            XCTAssertEqual(FeedEpisodeExtras.logReason(error, limit: limit), words, "\(error)")
        }
    }

    /// An error reading or attaching says TextMouth's own words for its own
    /// errors, and any other by its code and domain alone: the system's own
    /// words can name a package by its whole path.
    func testAnErrorReadingOrAttachingNeverNamesAPath() {
        XCTAssertEqual(FeedEpisodeExtras.logReason(of: PodcastChaptersError.notChapters), "not a chapters file")
        XCTAssertEqual(
            FeedEpisodeExtras.logReason(of: TimedTextError.notTimedText(.webVTT)),
            "The file isn't a WebVTT transcript TextMouth can read."
        )
        XCTAssertEqual(
            FeedEpisodeExtras.logReason(of: OutsideTranscriptError.alreadyTranscribed),
            "The book has a transcript already, so TextMouth kept it."
        )
        XCTAssertEqual(FeedEpisodeExtras.logReason(of: TranscriptTextError.textOnlyInCloud), "it is only in iCloud")
        let secret = NSError(
            domain: "NSCocoaErrorDomain",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "/Users/somebody/Library/Secret.tmb couldn't be read"]
        )
        XCTAssertEqual(FeedEpisodeExtras.logReason(of: secret), "error 4 in NSCocoaErrorDomain")
    }

    /// The version a file names for itself is the file's own text, and never
    /// reaches the log, whatever it holds: a line break in it would make a
    /// line of the log of its own.
    func testTheVersionAFileNamesNeverReachesTheLog() {
        let hostile = "9\nFEED_DOWNLOAD_FINISHED: x"
        let transcript = FeedEpisodeExtras.logReason(of: TimedTextError.unsupportedVersion(.podcastJSON, hostile))
        XCTAssertEqual(transcript, "it is a Podcasting 2.0 JSON transcript of a version TextMouth doesn't read")
        let chapters = FeedEpisodeExtras.logReason(of: PodcastChaptersError.unsupportedVersion(hostile))
        XCTAssertEqual(chapters, "its version is not one TextMouth reads")
        for reason in [transcript, chapters] {
            XCTAssertFalse(reason.contains("FEED_DOWNLOAD_FINISHED") || reason.contains("\n"), reason)
        }
    }

    /// A WebVTT link answering "not found" goes on to the JSON link after it,
    /// whose transcript the episode then takes, with its format recorded.
    func testTheNextTranscriptLinkIsTriedWhenOneFails() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasNext")
        let title = uniqueTitle()
        let feed = try await subscribe(
            world,
            title: title,
            // Listed the other way around: WebVTT is tried first all the same.
            transcripts: [("/t.json", "application/json"), ("/t.vtt", "text/vtt")],
            chapters: nil
        )
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", StubResponse(status: 404))
        world.server.serve("/t.json", try sampleResponse("podcast-transcript-json/transcript.json", type: "application/json"))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(try foundTranscript(of: book).source, TranscriptSource(origin: .podcast, format: .podcastJSON))
        XCTAssertEqual(world.server.requests(to: "/t.vtt").count, 1)
        XCTAssertEqual(world.server.requests(to: "/t.json").count, 1)
    }

    /// A link whose file does not read as its format goes on to the next
    /// too: a server answering a WebVTT link with a web page, then a SubRip
    /// link. Once one reads, no later link is asked for.
    func testAFileThatDoesNotReadGoesOnToTheNextLinkAndStopsAtTheFirstThatDoes() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasNotVTT")
        let title = uniqueTitle()
        let feed = try await subscribe(
            world,
            title: title,
            transcripts: [("/t.vtt", "text/vtt"), ("/t.srt", "application/x-subrip"), ("/u.srt", "application/x-subrip")],
            chapters: nil
        )
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", StubResponse(
            headers: ["Content-Type": "text/html"],
            body: Data("<html><!-- not found --><body>Not here</body></html>".utf8)
        ))
        world.server.serve("/t.srt", try sampleResponse("srt/tone4.srt", type: "application/x-subrip"))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(try foundTranscript(of: book).source, TranscriptSource(origin: .podcast, format: .subRip))
        XCTAssertEqual(world.server.requests(to: "/u.srt"), [], "a link after the one that read was asked for")
        XCTAssertEqual(
            debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(title) (The Tactile Atlas): WebVTT from \(world.server.host): "
                + "The file isn't a WebVTT transcript TextMouth can read.").count,
            1
        )
    }

    /// A transcript whose last cue ends 26 seconds past the end of the
    /// episode's 4 seconds of audio was made for other audio, as an episode
    /// with advertisements inserted makes one (the charter's decision 6): it
    /// is refused, the episode stays as it is, and the line says why.
    func testATranscriptRunningPastTheEndIsNotAttached() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasPastEnd")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", StubResponse(
            headers: ["Content-Type": "text/vtt"],
            body: Data("WEBVTT\n\n00:00.000 --> 00:01.000\nFirst.\n\n00:29.000 --> 00:30.000\nFar past the end.\n".utf8)
        ))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        XCTAssertFalse(TranscribedBooks.shared.contains(book.id))
        let refused = debugLogLines(containing: "FEED_TRANSCRIPT_NOT_ATTACHED: \(title) (The Tactile Atlas): The transcript runs to 30 seconds")
        XCTAssertEqual(refused.count, 1)
        XCTAssertTrue(refused.first?.contains("so it was made for other audio.") ?? false, "\(refused)")
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_ATTACHED: \(title)").count, 0)
    }

    /// Chapters beginning past the end of the audio were made for other
    /// audio too: the file is kept, but the book has its one chapter of
    /// today, and the debug log says why.
    func testChaptersRunningPastTheEndLeaveOneChapter() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasChaptersPastEnd")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [], chapters: "/c.json")
        try serveAudio(in: world, duration: 1)
        world.server.serve("/c.json", StubResponse(
            headers: ["Content-Type": "application/json+chapters"],
            body: Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Start"},{"startTime":60,"title":"Later"}]}"#.utf8)
        ))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(try BookContentAnalysisService.load(book: book).content.chapters.count, 1)
        XCTAssertGreaterThanOrEqual(
            debugLogLines(containing: "PODCAST_CHAPTERS_UNUSED: \(title): its last chapter begins past the end of the audio").count,
            1
        )
    }

    /// A video episode with a transcript downloads as it always did, and its
    /// outcome is told by one line: the transcript attached, or the reason it
    /// was not. Measuring video's sound is where an attach could fail, and a
    /// failure there must not touch the download.
    func testAVideoEpisodeWithATranscriptStillDownloadsAndSaysWhatBecameOfIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasVideo")
        let title = uniqueTitle()
        let feed = try await subscribe(
            world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil, audio: ("/video/tour.mp4", "video/mp4")
        )
        let video = try await FeedMediaFixtures.silentVideo(duration: 4)
        world.server.serve("/video/tour.mp4", FeedMediaFixtures.file(video, mimeType: "video/mp4"))
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        let episode = "\(title) (The Tactile Atlas)"
        let attached = debugLogLines(containing: "FEED_TRANSCRIPT_ATTACHED: \(episode): WebVTT, ").count
        let notAttached = debugLogLines(containing: "FEED_TRANSCRIPT_NOT_ATTACHED: \(episode): ").count
        XCTAssertEqual(attached + notAttached, 1, "the transcript's outcome was not told by exactly one line")
        // What the line says is what the package holds.
        if case .found = TranscriptStore.read(from: book.tmbDirectory) {
            XCTAssertEqual(attached, 1)
        } else {
            XCTAssertEqual(notAttached, 1)
        }
    }

    /// Links that carry no times are never asked for.
    func testLinksWithNoTimesAreNeverAskedFor() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasUntimed")
        let feed = try await subscribe(
            world,
            title: uniqueTitle(),
            transcripts: [("/t.html", "text/html"), ("/t.txt", "text/plain")],
            chapters: nil
        )
        try serveAudio(in: world, duration: 1)

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.server.requests(to: "/t.html"), [])
        XCTAssertEqual(world.server.requests(to: "/t.txt"), [])
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
    }

    /// A chapters file that isn't one leaves the episode one chapter, with
    /// a line saying why, and keeps no file beside its audio.
    func testAChaptersFileThatIsNotOneIsRefused() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasNotChapters")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [], chapters: "/c.json")
        try serveAudio(in: world, duration: 1)
        world.server.serve("/c.json", StubResponse(body: Data("<html>not chapters</html>".utf8)))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path))
        XCTAssertEqual(try BookContentAnalysisService.load(book: book).content.chapters.count, 1)
        XCTAssertEqual(
            debugLogLines(containing: "FEED_CHAPTERS_REFUSED: \(title) (The Tactile Atlas): from \(world.server.host): not a chapters file").count,
            1
        )
    }

    /// A transcript larger than the limit is refused with the limit named,
    /// through the limit `fetch` is given, and chapters through theirs.
    func testAFileLargerThanItsLimitIsRefused() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasLimits")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        let network = world.environment.network

        let small = await FeedEpisodeExtras.fetch(
            for: item, of: feed, network: network, discretionary: false, transcriptLimit: 100, chaptersLimit: 100
        )

        XCTAssertNil(small.transcript)
        XCTAssertNil(small.chapters)
        let episode = "\(title) (The Tactile Atlas)"
        XCTAssertEqual(debugLogLines(containing: "FEED_CHAPTERS_REFUSED: \(episode): from \(world.server.host): larger than the 0 KB").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(episode): WebVTT from \(world.server.host): larger than the 0 KB").count, 1)

        // With room for each, the same files are read: the limit, and
        // nothing else about them, refused them above.
        let roomy = await FeedEpisodeExtras.fetch(
            for: item, of: feed, network: network, discretionary: false, transcriptLimit: 10_000, chaptersLimit: 10_000
        )
        XCTAssertEqual(roomy.transcript?.format, .webVTT)
        XCTAssertEqual(roomy.chapters?.chapters.map(\.title), Self.sampleChapterTitles)
    }

    /// Without limits given, a chapters file of one byte over the megabyte
    /// the charter allows is refused, and one of exactly that size is read.
    func testChaptersAreHeldToAMegabyteWhenNoLimitIsGiven() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasMegabyte")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [], chapters: "/c.json")
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        let limit = TimedTextLimits.podcastChaptersBytes
        world.server.serve(
            "/c.json",
            StubResponse(body: paddedChaptersFile(ofBytes: limit)),
            StubResponse(body: paddedChaptersFile(ofBytes: limit + 1))
        )

        let exact = await FeedEpisodeExtras.fetch(for: item, of: feed, network: world.environment.network, discretionary: false)
        let over = await FeedEpisodeExtras.fetch(for: item, of: feed, network: world.environment.network, discretionary: false)

        XCTAssertEqual(exact.chapters?.chapters.map(\.title), ["Only"], "a file of exactly the limit was refused")
        XCTAssertNil(over.chapters, "a file past the limit was read")
    }

    // MARK: - The Download's Rules

    /// The rule's download fetches its files under the rule's own limits, as
    /// its audio was fetched: on no network with data limits. The listener's
    /// download fetches them on any, as its audio was.
    func testAnEpisodesFilesFollowItsDownloadsNetworkRules() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasRules")
        let feed = try await subscribe(world, title: uniqueTitle(), transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        for path in ["/audio/1.m4a", "/t.vtt", "/c.json"] {
            let request = try XCTUnwrap(world.server.requests(to: path).first, path)
            XCTAssertFalse(request.allowsExpensiveNetworkAccess, "\(path) of the rule's download was fetched on an expensive network")
            XCTAssertFalse(request.allowsConstrainedNetworkAccess, "\(path) of the rule's download was fetched on a constrained network")
        }

        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        for path in ["/audio/1.m4a", "/t.vtt", "/c.json"] {
            let request = try XCTUnwrap(world.server.requests(to: path).last, path)
            XCTAssertTrue(request.allowsExpensiveNetworkAccess, "\(path) of the listener's download kept off an expensive network")
            XCTAssertTrue(request.allowsConstrainedNetworkAccess, "\(path) of the listener's download kept off a constrained network")
        }
    }

    /// A file a network with data limits refuses is left out, and the
    /// episode downloads as it would have: the refusal does not make the
    /// download wait, as a refusal of its audio would.
    func testAFileANetworkRefusesLeavesTheEpisodeDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasMetered")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 1)
        world.server.serve("/t.vtt", .refusedOnAMeteredNetwork())

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(
            debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(title) (The Tactile Atlas): WebVTT from \(world.server.host): "
                + "refused on a network with data limits").count,
            1
        )
    }

    // MARK: - Time, Cancel, and Quit

    /// A server that never answers holds the episode up no longer than the
    /// limit on the whole: what was fetched by then is kept, the rest is left
    /// out, and one line says so.
    func testAFileThatDoesNotComeInTimeIsLeftOut() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasTimeLimit")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))
        world.server.serve("/t.vtt", hanging(try sampleResponse("vtt/tone4.vtt", type: "text/vtt")))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))

        let started = Date()
        let fetched = await FeedEpisodeExtras.fetch(
            for: item, of: feed, network: world.environment.network, discretionary: false, timeLimit: .seconds(1)
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), Self.hangingPause / 2, "the limit did not stop the fetch")
        XCTAssertEqual(fetched.chapters?.chapters.map(\.title), Self.sampleChapterTitles, "the chapters fetched in time were lost")
        XCTAssertNil(fetched.transcript)
        XCTAssertEqual(debugLogLines(containing: "FEED_EPISODE_FILES_TIMED_OUT: \(title) (The Tactile Atlas): still fetching after 1 seconds").count, 1)
    }

    /// Files that come at once return at once: the limit on the whole is a
    /// ceiling, not a wait. Its own timer is stopped as the fetching ends, so
    /// an episode whose files came in a moment does not wait the two minutes
    /// of the limit before it is imported.
    func testFilesThatComeAtOnceDoNotWaitForTheLimit() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasQuick")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))

        // The limit given is the one the app uses; a mistake that kept it
        // running would take all of it.
        let seconds = await secondsTaken {
            let fetched = await FeedEpisodeExtras.fetch(for: item, of: feed, network: world.environment.network, discretionary: false)
            XCTAssertNotNil(fetched.transcript)
            XCTAssertNotNil(fetched.chapters)
        }

        XCTAssertLessThan(seconds, 20, "the fetch waited for the limit on the whole")
    }

    /// A server that sends its file a byte at a time, so slowly that no
    /// request's own timeout ends it and the file's size limit is never
    /// reached in time, is held to the limit on the whole: the fetch returns
    /// when it runs out, with the transcript left out.
    func testAServerSendingAByteNowAndThenIsHeldToTheLimit() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasTrickle")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        var trickle = StubResponse(headers: ["Content-Type": "text/vtt"], body: Data(repeating: 0x20, count: 60))
        trickle.chunkSize = 1
        trickle.pause = 0.4
        world.server.serve("/t.vtt", trickle)
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))

        var fetched = FeedEpisodeExtras.Fetched()
        let seconds = await secondsTaken {
            fetched = await FeedEpisodeExtras.fetch(
                for: item, of: feed, network: world.environment.network, discretionary: false, timeLimit: .seconds(1)
            )
        }

        // The whole file would have taken 24 seconds.
        XCTAssertLessThan(seconds, 10, "the trickle held the fetch past the limit")
        XCTAssertNil(fetched.transcript)
        XCTAssertEqual(debugLogLines(containing: "FEED_EPISODE_FILES_TIMED_OUT: \(title) (The Tactile Atlas): still fetching after 1 seconds").count, 1)
    }

    /// Files fetched in time say nothing of the limit, and a task cancelled
    /// from outside stops at once and returns what it has, with no such line.
    func testACancelledFetchStopsAtOnceSayingNothingOfTheTime() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasFetchCancelled")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        world.server.serve("/t.vtt", hanging(try sampleResponse("vtt/tone4.vtt", type: "text/vtt")))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        let network = world.environment.network

        let started = Date()
        let task = Task {
            await FeedEpisodeExtras.fetch(for: item, of: feed, network: network, discretionary: false)
        }
        await waitFor("the transcript is asked for", timeout: 20) { !world.server.requests(to: "/t.vtt").isEmpty }
        task.cancel()
        let fetched = await task.value

        XCTAssertLessThan(Date().timeIntervalSince(started), Self.hangingPause / 2, "the cancel did not stop the fetch")
        XCTAssertEqual(fetched, FeedEpisodeExtras.Fetched())
        XCTAssertEqual(debugLogLines(containing: "FEED_EPISODE_FILES_TIMED_OUT: \(title)").count, 0)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_REFUSED: \(title)").count, 0, "a stop was logged as a refusal")
    }

    /// Cancel Download while the files come stops the download as it stops
    /// its audio: no book, the item not downloaded, and nothing left waiting
    /// to be imported.
    func testCancelDownloadWhileTheFilesComeStopsTheDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasCancel")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 1)
        world.server.serve("/t.vtt", hanging(try sampleResponse("vtt/tone4.vtt", type: "text/vtt")))

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the transcript is asked for", timeout: 20) { !world.server.requests(to: "/t.vtt").isEmpty }
        XCTAssertTrue(world.center.downloads.isDownloading("guid:ep-1", of: feed.id), "the download ended before its files came")

        let started = Date()
        XCTAssertEqual(world.center.cancelDownload("guid:ep-1", of: feed.id), .stopped)
        await waitFor("the download stops", timeout: 20) {
            !world.center.downloads.isDownloading("guid:ep-1", of: feed.id)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), Self.hangingPause / 2, "Cancel Download waited for the file")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
        XCTAssertTrue(world.library.library.books.isEmpty, "a cancelled download became a book")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path), [])
        XCTAssertEqual(debugLogLines(containing: "FEED_DOWNLOAD_CANCELLED: \(title)").count, 1)
    }

    /// The episode asked for again after Cancel Download stopped it while its
    /// files came downloads whole, as if the cancel had not happened: its
    /// audio from the start, its transcript this time, one book, and nothing
    /// left in the holding folder by either.
    func testAnEpisodeAskedForAgainAfterACancelDuringItsFilesDownloadsWhole() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasCancelAgain")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 4)
        // The first request for the transcript hangs; the second is answered.
        world.server.serve(
            "/t.vtt",
            hanging(try sampleResponse("vtt/tone4.vtt", type: "text/vtt")),
            try sampleResponse("vtt/tone4.vtt", type: "text/vtt")
        )

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the transcript is asked for", timeout: 20) { !world.server.requests(to: "/t.vtt").isEmpty }
        XCTAssertEqual(world.center.cancelDownload("guid:ep-1", of: feed.id), .stopped)
        await waitFor("the download stops", timeout: 20) {
            !world.center.downloads.isDownloading("guid:ep-1", of: feed.id)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path), [])

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.library.library.books.map(\.id), [book.id], "the episode is not in the library exactly once")
        XCTAssertEqual(try foundTranscript(of: book).source, TranscriptSource(origin: .podcast, format: .webVTT))
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a").count, 2, "the audio was not downloaded again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path), [])
        XCTAssertEqual(debugLogLines(containing: "FEED_DOWNLOAD_CANCELLED: \(title)").count, 1)
        XCTAssertEqual(debugLogLines(containing: "FEED_DOWNLOAD_FINISHED: \(title)").count, 1)
    }

    /// A quit while the files come imports nothing: the download is listed,
    /// and the next launch downloads the episode again, with its files.
    func testAQuitWhileTheFilesComeStartsTheEpisodeOverAtTheNextLaunch() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasQuit")
        // The relaunched engine works on its own: downloads by hand keep the
        // newest-N rule out of this test of the list kept at quit.
        FeedSettings.itemsPreference.write(.everyListedDownloadsByHand, to: world.preferences)
        let feed = try await subscribe(world, title: uniqueTitle(), transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 4)
        var slowly = try sampleResponse("vtt/tone4.vtt", type: "text/vtt")
        slowly.pause = 1
        world.server.serve("/t.vtt", slowly, try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the transcript is asked for", timeout: 20) { !world.server.requests(to: "/t.vtt").isEmpty }
        let downloads = world.center.downloads
        await downloads.stopForQuit()
        // The slow answer comes, and the download stops rather than imports.
        await waitFor("the download stops", timeout: 20) { downloads.current == nil }

        XCTAssertTrue(world.library.library.books.isEmpty, "a book was imported as TextMouth quit")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path), [])
        let listed = try JSONDecoder().decode(
            [FeedDownloadManager.SavedDownload].self,
            from: Data(contentsOf: downloads.savedAtQuitFile)
        )
        XCTAssertEqual(listed, [FeedDownloadManager.SavedDownload(feedID: feed.id, itemID: "guid:ep-1", origin: .listener)])
        await world.center.store.flush()

        let relaunched = await world.relaunch(self)
        let book = try await downloadedBook(world, center: relaunched, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(try foundTranscript(of: book).source, TranscriptSource(origin: .podcast, format: .webVTT))
    }

    // MARK: - Downloading Again

    /// An episode downloaded again into its kept package keeps the transcript
    /// kept with it, here one the listener edited, whatever the feed links
    /// now, and takes its chapters anew, since they went with the earlier
    /// file. A line says why the new transcript was left.
    func testAnEpisodeDownloadedAgainKeepsItsTranscriptAndTakesItsChaptersAnew() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasAgain")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 5))

        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id], "the package of a book with a place was not kept")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory).path),
            "the chapters stayed once their audio went"
        )

        // The listener's edit of the transcript kept with the episode.
        var edited = try foundTranscript(of: book)
        edited.editedAt = TranscriptFixtures.date
        _ = try TranscriptStore.write(edited, into: book.tmbDirectory)
        let keptBytes = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))

        // The feed's transcript has changed since.
        world.server.serve("/t.vtt", StubResponse(
            headers: ["Content-Type": "text/vtt"],
            body: Data("WEBVTT\n\n00:00.000 --> 00:01.000\nOther words.\n".utf8)
        ))
        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: restored.tmbDirectory)), keptBytes, "the listener's transcript was replaced")
        XCTAssertEqual(
            debugLogLines(containing: "FEED_TRANSCRIPT_NOT_ATTACHED: \(title) (The Tactile Atlas): "
                + "The book has a transcript already, so TextMouth kept it.").count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: restored.tmbDirectory).path))
        XCTAssertEqual(try BookContentAnalysisService.load(book: restored).index.allHeadings.map(\.text), Self.sampleChapterTitles)
    }

    /// The podcast's own transcript kept with an episode, which the listener
    /// never touched, gives way to the one fetched with a new download. A
    /// host inserting other advertisements makes a new file of each download,
    /// which the earlier transcript no longer fits, and the episode would
    /// show no text; with the new one, it does.
    func testThePodcastsOwnTranscriptGivesWayToTheOneFetchedWithANewDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasRefresh")
        let title = uniqueTitle()
        let feed = try await subscribe(world, title: title, transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 5))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id], "the package of a book with a place was not kept")

        // A new file, and the transcript made for it.
        try serveAudio(in: world, duration: 5)
        world.server.serve("/t.vtt", StubResponse(
            headers: ["Content-Type": "text/vtt"],
            body: Data("WEBVTT\n\n00:00.000 --> 00:01.000\nOther words.\n".utf8)
        ))
        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(restored.id, book.id)
        let transcript = try foundTranscript(of: restored)
        XCTAssertEqual(transcript.files.first?.sentences.map(\.text), ["Other words."])
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .podcast, format: .webVTT))
        let index = try XCTUnwrap(BookInfo.load(from: restored.tmbDirectory).contentIndex)
        XCTAssertNotNil(TranscriptTextLoader.load(for: restored, audioIndex: index).text, "the new file's transcript shows no text")
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_ATTACHED: \(title) (The Tactile Atlas): ").count, 2)
        XCTAssertEqual(debugLogLines(containing: "FEED_TRANSCRIPT_NOT_ATTACHED: \(title)").count, 0)
    }

    /// A chapters file that no longer comes when an episode is downloaded
    /// again leaves it none: nothing of the earlier file's is laid over the
    /// new audio. A kept package with no transcript takes the one fetched,
    /// and a reader watching the book hears of it, as it hears of a finished
    /// transcription.
    func testAnEpisodeDownloadedAgainTakesOnlyWhatComesWithIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasAgainNone")
        let feed = try await subscribe(world, title: uniqueTitle(), transcripts: [("/t.vtt", "text/vtt")], chapters: "/c.json")
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", StubResponse(status: 404))
        world.server.serve("/c.json", try sampleResponse("podcast-chapters-json/chapters.json", type: "application/json"))
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 5))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        world.library.bookUpdates.watch(book)
        var readersHeard = 0
        let subscription = world.library.bookUpdates.events(for: book.id).sink { event in
            if case .transcriptReplaced(_, let text) = event, text != nil {
                readersHeard += 1
            }
        }
        defer { subscription.cancel() }

        world.server.serve("/c.json", StubResponse(status: 404))
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(readersHeard, 1, "a reader of the episode did not hear of its transcript")
        XCTAssertTrue(TranscribedBooks.shared.contains(book.id), "the row does not say the episode is transcribed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.podcastChaptersPath(in: restored.tmbDirectory).path))
        XCTAssertEqual(try BookContentAnalysisService.load(book: restored).content.chapters.count, 1)
        XCTAssertEqual(try foundTranscript(of: restored).source, TranscriptSource(origin: .podcast, format: .webVTT))
    }

    // MARK: - Whose Transcript It Is

    /// An unopened episode whose only transcript is the podcast's own, which
    /// came with its download, holds nothing of the listener's: when its
    /// download goes, its package goes whole, so an automatic download that
    /// ages out leaves nothing behind, and no row stays on its feed's shelf.
    func testAnUnopenedEpisodeWithItsOwnTranscriptGoesWhole() async throws {
        let world = try FeedTestWorld(self, label: "FeedExtrasWhole")
        let feed = try await subscribe(world, title: uniqueTitle(), transcripts: [("/t.vtt", "text/vtt")], chapters: nil)
        try serveAudio(in: world, duration: 4)
        world.server.serve("/t.vtt", try sampleResponse("vtt/tone4.vtt", type: "text/vtt"))
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertNotNil(try? foundTranscript(of: book), "the episode has no transcript to test with")
        XCTAssertFalse(FeedItemPackage.holdsListenerState(book, package: book.tmbDirectory))

        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.deletedBookIDs, [book.id])
        XCTAssertEqual(report.keptPackageBookIDs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path), "the package stayed")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
    }

    /// A transcript the listener touched, or made, or that TextMouth cannot
    /// be sure of, keeps its package: each origin, each edit, a later
    /// layout, an origin a later TextMouth wrote, and a file that does not
    /// read. Only a podcast's own, untouched, leaves it free to go.
    func testOnlyAPodcastsOwnUntouchedTranscriptIsNotTheListeners() throws {
        let package = try makeSandboxDirectory("FeedExtrasWhose")
        let path = TextMouthPaths.transcriptPath(in: package)
        func write(_ transcript: Transcript) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(transcript).write(to: path)
        }
        func isTheListeners() -> Bool {
            FeedItemPackage.holdsListenersFiles(package)
        }
        func podcasts(_ change: (inout Transcript) -> Void = { _ in }) -> Transcript {
            var transcript = Transcript(
                version: Transcript.currentVersion,
                locale: OutsideTranscript.undeterminedLocale,
                model: OutsideTranscript.noRecognizer,
                app: .current,
                createdAt: TranscriptFixtures.date,
                files: [],
                source: TranscriptSource(origin: .podcast, format: .webVTT)
            )
            change(&transcript)
            return transcript
        }

        // Nothing there: nothing of the listener's.
        XCTAssertFalse(isTheListeners())

        try write(podcasts())
        XCTAssertFalse(isTheListeners(), "a podcast's own transcript counted as the listener's")
        XCTAssertTrue(TranscriptStore.holdsUntouchedPodcastTranscript(in: package))

        try write(podcasts { $0.editedAt = TranscriptFixtures.date })
        XCTAssertTrue(isTheListeners(), "an edited transcript did not count as the listener's")

        try write(podcasts {
            $0.cleanedUp = TranscriptCleanupNote(
                cleanedAt: TranscriptFixtures.date, rulesVersion: 1, rulesDate: "2026-10-30", rules: "built-in", corrections: 0
            )
        })
        XCTAssertTrue(isTheListeners(), "a cleaned-up transcript did not count as the listener's")

        try write(podcasts { $0.source = nil })
        XCTAssertTrue(isTheListeners(), "recognition's transcript did not count as the listener's")

        try write(podcasts { $0.source = TranscriptSource(origin: .attached, format: .webVTT, fileName: "a.vtt") })
        XCTAssertTrue(isTheListeners(), "an attached transcript did not count as the listener's")

        try write(podcasts { $0.source = TranscriptSource(origin: .imported, format: .subRip) })
        XCTAssertTrue(isTheListeners(), "an imported transcript did not count as the listener's")

        try write(podcasts { $0.source?.origin = "a-later-origin" })
        XCTAssertTrue(isTheListeners(), "an origin this TextMouth does not know did not count as the listener's")

        try write(podcasts { $0.version = Transcript.currentVersion + 1 })
        XCTAssertTrue(isTheListeners(), "a later layout did not count as the listener's")

        try Data("not a transcript".utf8).write(to: path)
        XCTAssertTrue(isTheListeners(), "a file that does not read did not count as the listener's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "asking moved a file that does not read aside")
    }

    /// A transcript.json that names its edit or its cleanup at all, even as
    /// null, is the listener's: it is the key that counts, not what it holds,
    /// so a file another version of TextMouth wrote with the key present and
    /// empty is never taken for untouched.
    func testAnEditOrCleanupKeyHoldingNullStillCountsAsTheListeners() throws {
        let package = try makeSandboxDirectory("FeedExtrasWhoseNull")
        let path = TextMouthPaths.transcriptPath(in: package)
        let podcasts = Transcript(
            version: Transcript.currentVersion,
            locale: OutsideTranscript.undeterminedLocale,
            model: OutsideTranscript.noRecognizer,
            app: .current,
            createdAt: TranscriptFixtures.date,
            files: [],
            source: TranscriptSource(origin: .podcast, format: .webVTT)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let written = try encoder.encode(podcasts)
        try written.write(to: path)
        XCTAssertTrue(TranscriptStore.holdsUntouchedPodcastTranscript(in: package), "the control was not untouched")

        for key in ["editedAt", "cleanedUp"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
            object[key] = NSNull()
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            XCTAssertFalse(TranscriptStore.holdsUntouchedPodcastTranscript(in: package), "a null \(key) was taken for untouched")
            XCTAssertTrue(FeedItemPackage.holdsListenersFiles(package), "a null \(key) did not keep the package")
        }
    }

    /// A transcript only in the cloud is taken for the listener's: reading it
    /// would download it, and a guess must not delete it.
    func testATranscriptOnlyInTheCloudIsTakenForTheListeners() throws {
        let package = try makeSandboxDirectory("FeedExtrasWhoseCloud")
        XCTAssertFalse(TranscriptStore.holdsUntouchedPodcastTranscript(in: package) { _ in
            throw POSIXError(.EDEADLK)
        })
    }

    /// A copy of a transcript set aside, or the one kept from before a
    /// cleanup, keeps the package whatever the transcript beside it is.
    func testAKeptCopyBesideAPodcastsOwnTranscriptIsTheListeners() throws {
        let package = try makeSandboxDirectory("FeedExtrasWhoseCopy")
        let podcasts = Transcript(
            version: Transcript.currentVersion,
            locale: OutsideTranscript.undeterminedLocale,
            model: OutsideTranscript.noRecognizer,
            app: .current,
            createdAt: TranscriptFixtures.date,
            files: [],
            source: TranscriptSource(origin: .podcast, format: .webVTT)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(podcasts).write(to: TextMouthPaths.transcriptPath(in: package))
        XCTAssertFalse(FeedItemPackage.holdsListenersFiles(package))

        try Data("{}".utf8).write(to: package.appendingPathComponent(TextMouthPaths.transcriptBeforeCleanupFileName))

        XCTAssertTrue(FeedItemPackage.holdsListenersFiles(package))
    }

    // MARK: - Support

    /// How long a `hanging(_:)` response keeps its client waiting: far longer
    /// than any test of it waits, and short enough that its background
    /// thread ends soon after its test does.
    private static let hangingPause: TimeInterval = 20

    /// `response`, held back for `hangingPause` seconds, as a server that has
    /// taken the request and does not answer.
    private func hanging(_ response: StubResponse) -> StubResponse {
        var held = response
        held.pause = Self.hangingPause
        return held
    }

    /// How many seconds `body` takes to run.
    private func secondsTaken(_ body: () async -> Void) async -> TimeInterval {
        let started = Date()
        await body()
        return Date().timeIntervalSince(started)
    }

    /// An episode's title no other test's lines of the debug log hold.
    private func uniqueTitle() -> String {
        "Episode \(UUID().uuidString.prefix(8))"
    }

    /// The transcript `book`'s package holds, failing the test without one.
    private func foundTranscript(
        of book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Transcript {
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            XCTFail("the episode has no transcript", file: file, line: line)
            throw CocoaError(.fileReadNoSuchFile)
        }
        return transcript
    }

    /// The format sample at `relativePath`, served as `type`.
    private func sampleResponse(_ relativePath: String, type: String) throws -> StubResponse {
        StubResponse(headers: ["Content-Type": type], body: try Data(contentsOf: copyOfFormatSample(relativePath)))
    }

    /// `duration` seconds of silence served as the episode's audio.
    private func serveAudio(in world: FeedTestWorld, duration: TimeInterval) throws {
        let audio = try FeedMediaFixtures.silentAAC(duration: duration)
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
    }

    /// A chapters file of exactly `count` bytes, one chapter titled "Only",
    /// its length made up by a field nothing reads.
    private func paddedChaptersFile(ofBytes count: Int) -> Data {
        let start = #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Only"}],"padding":""#
        let end = #""}"#
        return Data((start + String(repeating: "x", count: count - start.utf8.count - end.utf8.count) + end).utf8)
    }

    /// Starts `world`'s engine, and subscribes it to a feed of one episode,
    /// titled `title` ("guid:ep-1"), whose audio is at /audio/1.m4a, linking
    /// `transcripts`, each a path on the world's server with its type or
    /// none, and `chapters`, a path or none, in the feed's own elements.
    private func subscribe(
        _ world: FeedTestWorld,
        title: String,
        transcripts: [(path: String, type: String?)],
        chapters: String?,
        audio: (path: String, type: String) = (/audio/1.m4a, audio/mp4)
    ) async throws -> Feed {
        await world.start()
        let transcriptLinks = transcripts.map { link in
            let type = link.type.map { " type=\"\($0)\"" } ?? ""
            return "<podcast:transcript url=\"\(world.server.url(link.path).absoluteString)\"\(type)/>"
        }.joined()
        let chaptersLink = chapters.map {
            "<podcast:chapters url=\"\(world.server.url($0).absoluteString)\" type=\"application/json+chapters\"/>"
        } ?? ""
        world.server.serve("/feed.xml", .feed("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
        <channel><title>The Tactile Atlas</title><link>https://show.example/</link>
        <description>A show for tests.</description>
        <item><title>\(title)</title><guid isPermaLink="false">ep-1</guid>
        <enclosure url="\(world.server.url(audio.path).absoluteString)" length="1000" type="\(audio.type)"/>
        \(transcriptLinks)\(chaptersLink)
        </item>
        </channel></rss>
        """))
        return try await world.subscribe("/feed.xml")
    }
}
