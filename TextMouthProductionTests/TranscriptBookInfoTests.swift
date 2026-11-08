import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Book Information says where an audiobook's transcript came from (FMT23,
/// FMT25): one read-only "Transcript" detail, in the library's and reader's
/// editor for an audiobook and in the read-only sheet of an episode, worded
/// as the Transcribe Audio sheet words the same facts, and left out for a
/// book with no transcript and for a text book.
@MainActor
final class TranscriptBookInfoTests: XCTestCase {

    // MARK: - The Words

    /// A transcript recognition made says when, and in which language.
    func testARecognizedTranscriptSaysWhenAndInWhichLanguage() {
        let transcript = TranscriptFixtures.transcript([], locale: "en-US")
        let language = TranscriptionLanguage.name(of: "en-US")

        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(of: transcript),
            "Transcribed on \(Self.day), in \(language)."
        )
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(of: TranscriptFixtures.transcript([], locale: "de-DE")),
            "Transcribed on \(Self.day), in \(TranscriptionLanguage.name(of: "de-DE"))."
        )
    }

    /// A transcript from outside says where it came from, as the sheet does
    /// and without the sheet's last sentence, for each origin, with and
    /// without a file's name, and for an origin a later TextMouth wrote
    /// (`knownOrigin` nil). It names no language, whatever its locale.
    func testATranscriptFromOutsideSaysWhereItCameFrom() throws {
        func line(_ source: TranscriptSource) -> String {
            TranscriptionWording.bookInfoLine(of: Self.transcript(from: source))
        }
        let later = try JSONDecoder().decode(
            TranscriptSource.self,
            from: Data(#"{"fileName":"evening.ttml","format":"ttml","origin":"radio"}"#.utf8)
        )

        XCTAssertEqual(
            line(TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt")),
            "Attached from “lecture.vtt” on \(Self.day)."
        )
        XCTAssertEqual(
            line(TranscriptSource(origin: .attached, format: .subRip)),
            "Attached from a SubRip file on \(Self.day)."
        )
        XCTAssertEqual(
            line(TranscriptSource(origin: .imported, format: .webVTT, fileName: "lecture.vtt")),
            "Attached from “lecture.vtt” when the book was imported, on \(Self.day)."
        )
        XCTAssertEqual(
            line(TranscriptSource(origin: .podcast, format: .podcastJSON)),
            "The podcast's own transcript, downloaded with the episode on \(Self.day)."
        )
        XCTAssertNil(later.knownOrigin, "the test's origin must be one this TextMouth does not know")
        XCTAssertEqual(line(later), "Attached on \(Self.day).")
    }

    /// An edited transcript says when it was edited, a cleaned-up one when it
    /// was cleaned up, and one that was both says the edit first; for a
    /// transcript from outside too. Neither says anything about transcribing
    /// again.
    func testAnEditedOrCleanedUpTranscriptSaysSo() {
        let editDay = TranscriptionWording.day(Self.editedDate)
        let cleanDay = TranscriptionWording.day(Self.cleanedDate)
        let language = TranscriptionLanguage.name(of: "en-US")

        var edited = TranscriptFixtures.transcript([])
        edited.editedAt = Self.editedDate
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(of: edited),
            "Transcribed on \(Self.day), in \(language). You edited it on \(editDay)."
        )

        var cleaned = TranscriptFixtures.transcript([])
        cleaned.cleanedUp = Self.cleanupNote
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(of: cleaned),
            "Transcribed on \(Self.day), in \(language). You cleaned it up on \(cleanDay)."
        )

        var both = Self.transcript(from: TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt"))
        both.editedAt = Self.editedDate
        both.cleanedUp = Self.cleanupNote
        let line = TranscriptionWording.bookInfoLine(of: both)
        XCTAssertEqual(
            line,
            "Attached from “lecture.vtt” on \(Self.day). You edited it on \(editDay). You cleaned it up on \(cleanDay)."
        )
        XCTAssertFalse(line.contains("Transcribing again"), "the sheet's warning leaked into Book Information")
    }

    /// What a read of the transcript found decides the line: none for a book
    /// with no transcript and for one set aside as unusable, as the sheet
    /// counts them; words for one only in iCloud and for a later TextMouth's.
    func testEachWayAReadCanEndHasItsLineOrNone() {
        XCTAssertNil(TranscriptionWording.bookInfoLine(for: .missing))
        XCTAssertNil(TranscriptionWording.bookInfoLine(for: .unusable("it is not valid JSON")))
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(for: .inCloud),
            "The transcript is only in the cloud. Its details appear once the book is downloaded."
        )
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(for: .unsupportedVersion(7)),
            "This book has a transcript made by a later version of TextMouth."
        )
        XCTAssertEqual(
            TranscriptionWording.bookInfoLine(for: .found(TranscriptFixtures.transcript([]))),
            TranscriptionWording.bookInfoLine(of: TranscriptFixtures.transcript([]))
        )
        XCTAssertEqual(TranscriptionWording.bookInfoLabel, "Transcript")
    }

    /// The sentences the sheet and Book Information share are said once: the
    /// sheet's lines still read exactly as they did.
    func testTheSheetsLinesAreUnchanged() {
        XCTAssertEqual(
            TranscriptionWording.alreadyTranscribed(on: TranscriptFixtures.date, languageName: "English"),
            "Transcribed on \(Self.day), in English. Transcribing again replaces this transcript."
        )
        XCTAssertEqual(
            TranscriptionWording.transcriptFromLaterVersion,
            "This book has a transcript made by a later version of TextMouth. Transcribing again replaces it."
        )
    }

    // MARK: - The Details of an Episode

    /// An episode's "Transcript" detail follows its format, is left out
    /// without a line, and an article, which has no transcript, never shows
    /// one even if a line is passed.
    func testAnEpisodesTranscriptDetailFollowsItsFormat() {
        let metadata = AudioMetadata(
            title: "Ep. 368", artist: "Small Hours Audio", album: "Finish It!", genre: "Podcast", year: "2026",
            duration: "1:04:00", fileFormat: "MP3"
        )
        let line = "The podcast's own transcript, downloaded with the episode on \(Self.day)."
        let episode = Book(title: "Ep. 368", format: .audio, filePath: "/Ep. 368.m4a", md5Hash: "")

        let with = FeedItemBookInfoWording.details(
            of: episode, info: .audio(metadata, isCloudOnly: false), feedTitle: nil, transcriptLine: line
        )
        let labels = with.map(\.label)
        XCTAssertEqual(with.first { $0.label == "Transcript" }, BookInfoDetail(label: "Transcript", value: line))
        XCTAssertEqual(labels.firstIndex(of: "Transcript"), labels.firstIndex(of: "Format").map { $0 + 1 })

        let without = FeedItemBookInfoWording.details(of: episode, info: .audio(metadata, isCloudOnly: false), feedTitle: nil)
        XCTAssertFalse(without.contains { $0.label == "Transcript" })

        let article = Book(title: "Night trams", format: .html, filePath: "/Night trams.html", md5Hash: "")
        let articleDetails = FeedItemBookInfoWording.details(of: article, info: .simple, feedTitle: nil, transcriptLine: line)
        XCTAssertFalse(articleDetails.contains { $0.label == "Transcript" }, "an article was given a transcript detail")
    }

    // MARK: - The Loading

    /// The line for a book reads its package's transcript: none for a text
    /// book, a book without a package, and an audiobook without a transcript;
    /// and for each origin, the line the words give.
    func testTheLineIsReadFromTheBooksPackage() async throws {
        let world = try makeIntegrationWorld("Transcript Book Info")
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [1])

        let none = await TranscriptStore.bookInfoLine(for: book)
        XCTAssertNil(none, "a book with no transcript has a line")

        try TranscriptStore.write(TranscriptFixtures.twoFiles, into: book.tmbDirectory)
        let recognized = await TranscriptStore.bookInfoLine(for: book)
        XCTAssertEqual(recognized, "Transcribed on \(Self.day), in \(TranscriptionLanguage.name(of: "en-US")).")

        var attached = TranscriptFixtures.twoFiles
        attached.source = TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt")
        attached.editedAt = Self.editedDate
        try TranscriptStore.write(attached, into: book.tmbDirectory)
        let fromFile = await TranscriptStore.bookInfoLine(for: book)
        XCTAssertEqual(
            fromFile,
            "Attached from “lecture.vtt” on \(Self.day). You edited it on \(TranscriptionWording.day(Self.editedDate))."
        )

        var text = book
        text.format = .txt
        let forText = await TranscriptStore.bookInfoLine(for: text)
        XCTAssertNil(forText, "a text book has a line")

        var unpackaged = book
        unpackaged.tmbDirectoryName = ""
        let forUnpackaged = await TranscriptStore.bookInfoLine(for: unpackaged)
        XCTAssertNil(forUnpackaged, "a book without a package has a line")
    }

    // MARK: - The Model Behind Both Sheets

    /// The model holds nothing until it has read, and nothing for no book;
    /// it holds the line read for a book, and drops it when asked about
    /// another book that has none, so one book's line never shows beside
    /// another's. It asks the reader only for a book it was given.
    func testTheModelHoldsTheLineOfTheBookItWasLastAskedAbout() async {
        let asked = AskedBooks()
        let model = TranscriptBookInfoModel(reader: { book in
            await asked.add(book.title)
            return book.title == "Has one" ? "Its line." : nil
        })
        XCTAssertNil(model.line, "a line before any read")

        await model.load(for: nil)
        let askedAboutNobody = await asked.titles
        XCTAssertNil(model.line)
        XCTAssertEqual(askedAboutNobody, [], "the reader was asked with no book")

        await model.load(for: Book(title: "Has one", format: .audio, filePath: "/a.m4a", md5Hash: ""))
        XCTAssertEqual(model.line, "Its line.")

        await model.load(for: Book(title: "Has none", format: .audio, filePath: "/b.m4a", md5Hash: ""))
        XCTAssertNil(model.line, "the first book's line stayed for the second")
        let askedAbout = await asked.titles
        XCTAssertEqual(askedAbout, ["Has one", "Has none"])
    }

    /// A read that finishes after the sheet moved on, its task cancelled, is
    /// dropped: the model never shows a line nobody is waiting for.
    func testAReadThatFinishesAfterItsTaskWasCancelledIsDropped() async {
        let model = TranscriptBookInfoModel(reader: { _ in
            // Waits for the cancellation, at most a few thousand turns.
            for _ in 0..<5_000 where !Task.isCancelled { await Task.yield() }
            return "A stale line."
        })
        let book = Book(title: "Slow", format: .audio, filePath: "/s.m4a", md5Hash: "")

        let task = Task { await model.load(for: book) }
        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        await task.value

        XCTAssertNil(model.line, "a cancelled read set the line")
    }

    /// With the reader the app uses, the model holds the line of a real
    /// package's transcript, as the sheets show it, and the spoken detail
    /// reads "Transcript: " and then the line.
    func testTheModelReadsARealPackage() async throws {
        let world = try makeIntegrationWorld("Transcript Book Info Model")
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [1])
        var transcript = TranscriptFixtures.twoFiles
        transcript.source = TranscriptSource(origin: .podcast, format: .podcastJSON)
        try TranscriptStore.write(transcript, into: book.tmbDirectory)
        let model = TranscriptBookInfoModel()

        await model.load(for: book)

        let line = "The podcast's own transcript, downloaded with the episode on \(Self.day)."
        XCTAssertEqual(model.line, line)
        XCTAssertEqual(TranscriptionWording.bookInfoSpokenDetail(line), "Transcript: \(line)")
    }

    // MARK: - The Sheets

    /// The editor of an audiobook in the library and the reader holds the
    /// detail, shown and spoken as "Transcript: <line>", for a book with a
    /// transcript of each origin, and none for a book without one or when it
    /// is not given the book.
    func testTheEditorHoldsTheDetailOfAnAudiobookWithATranscript() async throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let world = try makeIntegrationWorld("Transcript Book Info Editor")
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [1])
        let metadata = Self.audioMetadata

        // No transcript yet: the other details are drawn, this one is not.
        try hostEditor(metadata, book: book) { hosting in
            XCTAssertFalse(self.hasLabel(startingWith: "Transcript", in: hosting), "a book without a transcript shows the detail")
        }

        for (source, expected) in Self.origins {
            var transcript = TranscriptFixtures.twoFiles
            transcript.source = source
            try TranscriptStore.write(transcript, into: book.tmbDirectory)
            let line = expected
            try hostEditor(metadata, book: book, expecting: "Transcript: \(line)") { hosting in
                XCTAssertFalse(self.accessibilityElements(labelled: "Transcript: \(line)", in: hosting).isEmpty)
            }
        }

        // Given no book, the editor has nothing to read and shows nothing.
        try hostEditor(metadata, book: nil) { hosting in
            XCTAssertFalse(self.hasLabel(startingWith: "Transcript", in: hosting), "an editor without a book shows the detail")
        }
    }

    /// The read-only sheet of an episode holds the detail, as "Transcript,
    /// <line>", for a transcript of each origin, and none without one.
    func testTheEpisodeSheetHoldsTheDetailOfAnEpisodeWithATranscript() async throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let world = try makeIntegrationWorld("Transcript Book Info Sheet")
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [1])
        let info = LibraryBookInfo.audio(Self.audioMetadata, isCloudOnly: false)

        try hostSheet(book, info: info, expecting: "Title, Harbour Captions") { hosting in
            XCTAssertFalse(self.hasLabel(startingWith: "Transcript", in: hosting), "a book without a transcript shows the detail")
        }

        for (source, expected) in Self.origins {
            var transcript = TranscriptFixtures.twoFiles
            transcript.source = source
            try TranscriptStore.write(transcript, into: book.tmbDirectory)
            let line = expected
            try hostSheet(book, info: info, expecting: "Transcript, \(line)") { hosting in
                XCTAssertFalse(self.accessibilityElements(labelled: "Transcript, \(line)", in: hosting).isEmpty)
            }
        }

        // A text book has no transcript, whatever its package holds.
        var text = book
        text.format = .txt
        try hostSheet(text, info: .simple, expecting: "Title, Harbour Captions") { hosting in
            XCTAssertFalse(self.hasLabel(startingWith: "Transcript", in: hosting), "a text book shows the detail")
        }
    }

    // MARK: - Helpers

    /// The titles of the books a stub reader was asked about, in order.
    private actor AskedBooks {
        private(set) var titles: [String] = []

        /// Notes that the book titled `title` was asked about.
        func add(_ title: String) {
            titles.append(title)
        }
    }

    /// The day of `TranscriptFixtures.date`, as the lines say it.
    private static var day: String { TranscriptionWording.day(TranscriptFixtures.date) }

    /// When the user last edited a transcript in these tests.
    private static let editedDate = Date(timeIntervalSince1970: 1_790_200_000)
    /// When the user last cleaned a transcript up in these tests.
    private static let cleanedDate = Date(timeIntervalSince1970: 1_790_400_000)

    /// A cleanup note made on `cleanedDate`.
    private static var cleanupNote: TranscriptCleanupNote {
        TranscriptCleanupNote(cleanedAt: cleanedDate, rulesVersion: 1, rulesDate: "2026-10-04", rules: "built-in", corrections: 3)
    }

    /// The tags the sheets under test are given.
    private static let audioMetadata = AudioMetadata(
        title: "Harbour Captions", artist: "Small Hours Audio", album: "", genre: "", year: "",
        duration: "1:04:00", fileFormat: "MP3"
    )

    /// A transcript with no files, with `source` as where it came from.
    private static func transcript(from source: TranscriptSource) -> Transcript {
        var transcript = TranscriptFixtures.transcript([], locale: "und")
        transcript.source = source
        return transcript
    }

    /// Sources of each origin, with the line each is told by.
    private static let origins: [(TranscriptSource, String)] = [
        (TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt"), "Attached from “lecture.vtt” on \(day)."),
        (
            TranscriptSource(origin: .imported, format: .subRip, fileName: "lecture.srt"),
            "Attached from “lecture.srt” when the book was imported, on \(day)."
        ),
        (
            TranscriptSource(origin: .podcast, format: .podcastJSON),
            "The podcast's own transcript, downloaded with the episode on \(day)."
        ),
    ]

    /// Whether some accessibility element below `root` has a label that
    /// starts with `prefix`.
    private func hasLabel(startingWith prefix: String, in root: Any) -> Bool {
        guard let node = root as? NSAccessibilityProtocol else { return false }
        if let label = node.accessibilityLabel(), label.hasPrefix(prefix) { return true }
        return (node.accessibilityChildren() ?? []).contains { hasLabel(startingWith: prefix, in: $0) }
    }

    /// Hosts the editor of an audiobook with `metadata`, given `book`, until
    /// it has drawn the label `expecting` (its Duration when none is given,
    /// so a test that expects nothing still waits for the sheet), and passes
    /// the hosting view to `body`. The read is given the same time as the
    /// drawing, so a detail that never comes is missed only if it never
    /// would have.
    private func hostEditor(
        _ metadata: AudioMetadata,
        book: Book?,
        expecting label: String? = nil,
        _ body: (NSView) throws -> Void
    ) throws {
        let editor = MetadataEditorView(audioMetadata: metadata, book: book) { _, _ in }
        let wanted = label ?? "Duration: \(metadata.duration)"
        try withHostedView(editor, size: NSSize(width: 450, height: 550), until: {
            !self.accessibilityElements(labelled: wanted, in: $0).isEmpty
        }) { hosting in
            // The Duration is drawn at once; give the transcript's read time
            // to come back before a test says it never did.
            if label == nil { _ = waitUntil(timeout: 1) { false } }
            XCTAssertFalse(accessibilityElements(labelled: wanted, in: hosting).isEmpty, "\(wanted) was not drawn")
            try body(hosting)
        }
    }

    /// Hosts the read-only sheet of `book` until it has drawn the label
    /// `expecting`, and passes the hosting view to `body`.
    private func hostSheet(
        _ book: Book,
        info: LibraryBookInfo,
        expecting label: String,
        _ body: (NSView) throws -> Void
    ) throws {
        let sheet = FeedItemBookInfoSheet(book: book, info: info, feedTitle: nil)
        try withHostedView(sheet, size: NSSize(width: 450, height: 440), until: {
            !self.accessibilityElements(labelled: label, in: $0).isEmpty
        }) { hosting in
            // For a book with no transcript the label waited for is a
            // detail drawn at once; give the transcript's read time to come
            // back before a test says it never did.
            if !label.hasPrefix("Transcript") { _ = waitUntil(timeout: 1) { false } }
            XCTAssertFalse(accessibilityElements(labelled: label, in: hosting).isEmpty, "\(label) was not drawn")
            try body(hosting)
        }
    }
}
