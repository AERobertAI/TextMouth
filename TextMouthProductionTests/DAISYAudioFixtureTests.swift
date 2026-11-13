import XCTest
import ZIPFoundation
@testable import TextMouth

/// The DAISY audio books some checkouts keep in TestData, read by
/// TextMouth's own code: the check the library makes for audio before it
/// imports a DAISY ZIP as an audiobook, the SMIL parser on a real book's
/// synchronization files, and each book's import as the library imports
/// one, whose sections must play inside their files, in reading order, in
/// the clip layout recorded for the book. Until these, only in-memory
/// packages and silent WAVs tested a DAISY book's clips (a follow-up the
/// DAISY multi-clip work noted on October 3).
///
/// Git ignores the books, so a linked worktree finds them in the main
/// checkout's TestData (`optionalTestDataArchive(_:)`), and each test skips,
/// saying why, only when no checkout keeps its book. The first three were
/// legacy scenarios in DAISYAudioTests.swift that returned before asserting
/// anything where a book was missing, and so passed in every worktree.
/// Nothing plays: the books' files are only measured, as the import
/// measures them.
@MainActor
final class DAISYAudioFixtureTests: XCTestCase {

    // MARK: - Finding the Audio

    /// Fire Safety, a DAISY 2.02 book read by a person, holds audio by the
    /// check the library makes before it imports a DAISY ZIP as an
    /// audiobook.
    func testFireSafetyIsFoundToHoldAudio() throws {
        let found = try hasAudio(TranscriptionFixtureTests.fireSafety)

        XCTAssertTrue(found, "Fire Safety, a DAISY 2.02 book, was not found to hold audio")
    }

    /// Are You Ready, a DAISY 3 book read by a synthetic voice, holds audio
    /// by the same check.
    func testAreYouReadyIsFoundToHoldAudio() throws {
        let found = try hasAudio(TranscriptionFixtureTests.areYouReady)

        XCTAssertTrue(found, "Are You Ready, a DAISY 3 book, was not found to hold audio")
    }

    // MARK: - A Real Book's SMIL Files

    /// Fire Safety's SMIL files hold audio clips as the app's SMIL parser
    /// reads them: the first that holds any, in the archive's order, starts
    /// with the book's first recording, its title heading read aloud, in a
    /// first clip from 0 to 3.578 seconds.
    func testFireSafetysSMILFilesHoldAudioClips() throws {
        let archive = try Archive(url: try optionalTestDataArchive(TranscriptionFixtureTests.fireSafety), accessMode: .read)
        let provider = ArchiveFileProvider(archive: archive)
        var firstClip: DAISYAudioClip?
        for path in provider.listFiles() where path.lowercased().hasSuffix(".smil") {
            firstClip = try parseDAISYAudioSMIL(String(decoding: try provider.readFile(at: path), as: UTF8.self)).first
            if firstClip != nil { break }
        }

        let clip = try XCTUnwrap(firstClip, "no SMIL file in Fire Safety holds an audio clip")
        XCTAssertEqual(clip.file, "01_Fire_Safety__by_Wendy_Blaxland.mp3")
        XCTAssertEqual(clip.startTime, 0, accuracy: Self.millisecond / 2)
        XCTAssertEqual(clip.endTime, 3.578, accuracy: Self.millisecond / 2)
    }

    // MARK: - SMIL Clock Values

    /// A SMIL timecount counts in the metric it ends with: milliseconds,
    /// seconds, minutes, or hours, and in seconds with none. "500ms" was read
    /// as 0, since its trailing "s" was taken off and "500m" is no number.
    func testTimecountsAreReadInTheirMetric() {
        let cases: [(String, Double)] = [
            ("500ms", 0.5), ("1500ms", 1.5), ("2min", 120), ("1.5min", 90), ("1h", 3600), ("0.5h", 1800),
            ("38.228s", 38.228), ("38.228", 38.228), ("npt=500ms", 0.5), ("npt=38.228s", 38.228),
            (" 250ms ", 0.25), ("500MS", 0.5), ("2MIN", 120),
        ]
        for (value, seconds) in cases {
            XCTAssertEqual(DAISYAudioSMILParser.parseTime(value), seconds, accuracy: 1e-9, value)
        }
    }

    /// The readings from before still read as they did: clock values with
    /// hours, minutes, and a fraction, with or without a trailing "s", and
    /// text that is no time at all is 0.
    func testClockValuesAndNonsenseAreReadAsBefore() {
        let cases: [(String, Double)] = [
            ("0:02:43.650", 163.65), ("1:00:00", 3600), ("02:30", 150), ("npt=0:00:05.5", 5.5),
            ("0:02:43.650s", 163.65), ("", 0), ("soon", 0), ("ms", 0), ("min", 0), ("xms", 0),
        ]
        for (value, seconds) in cases {
            XCTAssertEqual(DAISYAudioSMILParser.parseTime(value), seconds, accuracy: 1e-9, value.debugDescription)
        }
    }

    /// A clip whose SMIL file gives its times in milliseconds starts and ends
    /// where they say.
    func testAClipGivenInMillisecondsStartsWhereItSays() throws {
        let smil = """
        <smil><body><seq><par id="p1"><text src="a.xhtml#t1"/>\
        <audio src="a.mp3" clipBegin="500ms" clipEnd="2500ms"/></par></seq></body></smil>
        """
        let clip = try XCTUnwrap(parseDAISYAudioSMIL(smil).first)
        XCTAssertEqual(clip.startTime, 0.5, accuracy: Self.rounding)
        XCTAssertEqual(clip.endTime, 2.5, accuracy: Self.rounding)
    }

    // MARK: - Whole Books

    /// Fire Safety, imported as the library imports it, plays every section
    /// inside its files, in reading order, in the clip layout recorded for
    /// it: 51 sections, each one clip of its heading's own recording.
    func testFireSafetyPlaysEverySectionInsideItsFilesInReadingOrder() async throws {
        try await assertSectionsOfImportedBook(TranscriptionFixtureTests.fireSafety, recordedLayout: Self.fireSafetyLayout)
    }

    /// Are You Ready, imported as the library imports it, plays every
    /// section inside its files, in reading order, in the clip layout
    /// recorded for it: 33 sections, each one clip of its heading's own
    /// recording.
    func testAreYouReadyPlaysEverySectionInsideItsFilesInReadingOrder() async throws {
        try await assertSectionsOfImportedBook(TranscriptionFixtureTests.areYouReady, recordedLayout: Self.areYouReadyLayout)
    }

    // MARK: - The Recorded Layouts

    /// `TextPipelineFixtures.digest(_:)` of each book's `layout(of:)`, the
    /// sections its import converts from its SMIL files, recorded on October
    /// 30, 2026 from the archives in the main checkout's TestData (Fire
    /// Safety 10,148,230 bytes, Are You Ready 13,686,095). They were worked
    /// out first by a script that read each book's NCC or NCX, OPF spine,
    /// and SMIL files without TextMouth's code, following the rules the
    /// converter documents (DAISYParser+Audio.swift), and these tests then
    /// found the same digests. In both books each heading's section is one
    /// clip of its own recording, from its start to its last phrase's end:
    /// the converter joins the 263 and 571 phrases the SMIL files time. Are
    /// You Ready's first recording, its title and author read aloud
    /// (speechgen0001.mp3), comes before its first heading, so no section
    /// plays it.
    ///
    /// A deliberate change to the conversion changes these: the failure
    /// message shows the layout and digest found, which replace these once
    /// the new layout has been checked against the books.
    static let fireSafetyLayout = "dfb29d2b0782f803"
    static let areYouReadyLayout = "187701a59ca2b561"

    /// A millisecond, in seconds: the finest time a DAISY book's SMIL files
    /// give a clip.
    static let millisecond: TimeInterval = 0.001

    /// How far apart two times may lie and still count as one: the saved
    /// index keeps each clip as a start and a length, so an end read back
    /// as their sum can be off by a rounding error. A microsecond is far
    /// less than one sample of audio at any rate.
    static let rounding: TimeInterval = 0.000_001

    // MARK: - Helpers

    /// Whether the TestData book `name` holds audio by the library's own
    /// check, `DAISYAudioConverter.hasAudio(in:)`. Skips the test when no
    /// checkout keeps the book.
    private func hasAudio(_ name: String) throws -> Bool {
        let archive = try Archive(url: try optionalTestDataArchive(name), accessMode: .read)
        return DAISYAudioConverter.hasAudio(in: ArchiveFileProvider(archive: archive))
    }

    /// Imports the TestData book `name` into a library of this test's own,
    /// as the library imports a DAISY ZIP that holds audio, opens it as the
    /// reader opens it, and checks the sections it plays: every clip inside
    /// its file (`assertInsideTheirFiles`), the book in reading order
    /// (`assertInReadingOrder`), and the clips those of the layout the
    /// import converted from the book's SMIL files, its manifest.json, each
    /// end moved back to its file's end where it ran past it, as the import
    /// moves one. That layout's digest must be `recordedLayout`. Skips the
    /// test when no checkout keeps the book.
    private func assertSectionsOfImportedBook(_ name: String, recordedLayout: String, line: UInt = #line) async throws {
        let source = try optionalTestDataArchive(name)
        let world = try makeIntegrationWorld("DAISY Audio Fixture")
        let folder = world.folder.path
        // Imported off the main thread, as the library imports, since
        // reading and measuring the audio would hold it up.
        let book = try await OffMainWork.runThrowing {
            try FileImportService.importDAISYAudioZipWithReport(from: source, toFolder: folder).book
        }
        world.library.library.addBook(book)

        // The sections as the reader opens them, from the index the import
        // saved, and as the import converted them.
        let opened = try await OffMainWork.runThrowing { try BookContentAnalysisService.load(book: book).audioSegments }
        let played = try XCTUnwrap(opened, "\(name) opened without sections", line: line)
        let converted = try XCTUnwrap(
            AudioManifest.read(inAudioFolder: book.bookFileURL)?.manifest.segments,
            "\(name) was imported without sections in its manifest",
            line: line
        )
        let lengths = await measuredLengths(of: played, inAudioFolder: book.bookFileURL, book: name, line: line)

        assertInsideTheirFiles(played, lengths: lengths, book: name, line: line)
        assertInReadingOrder(played, book: name, line: line)
        let fitted = converted.map { section in
            section.mappingClips { clip in
                AudioClip(file: clip.file, startTime: clip.startTime, endTime: min(clip.endTime, lengths[clip.file] ?? clip.endTime))
            }
        }
        XCTAssertEqual(Self.layout(of: played), Self.layout(of: fitted), "\(name) plays other clips than its import converted", line: line)
        let layout = Self.layout(of: converted)
        XCTAssertEqual(
            TextPipelineFixtures.digest(layout),
            recordedLayout,
            "\(name)'s clip layout changed: \(converted.count) sections, \(converted.flatMap(\.clips).count) clips:\n\(layout)",
            line: line
        )
    }

    /// How long each file that `sections` play lasts, by its path in the
    /// book's audio folder `folder`, as the import measures it
    /// (`AudioMediaProber.avFoundation`, which decodes a moment of each
    /// file's start and end and plays nothing). A file that cannot be
    /// measured fails the test, naming the problem, and is left out.
    private func measuredLengths(
        of sections: [AudioSegment],
        inAudioFolder folder: URL,
        book: String,
        line: UInt
    ) async -> [String: TimeInterval] {
        let files = Set(sections.flatMap { $0.clips.map(\.file) }).sorted()
        let outcomes = await AudioMediaProber.avFoundation.probeEach(files.map { folder.appendingPathComponent($0) })
        var lengths: [String: TimeInterval] = [:]
        for (file, outcome) in zip(files, outcomes) {
            switch outcome {
            case .success(let seconds):
                lengths[file] = seconds
            case .failure(let problem):
                XCTFail("\(book): \(file) cannot be measured: \(problem.reason)", line: line)
            }
        }
        return lengths
    }

    /// Fails for each clip of `sections` that does not lie inside its file
    /// as `lengths` measures it: one that starts before 0 or at or after
    /// the file's end, ends at or before it starts, or ends past the file's
    /// end by more than `rounding`.
    private func assertInsideTheirFiles(_ sections: [AudioSegment], lengths: [String: TimeInterval], book: String, line: UInt) {
        for (number, section) in sections.enumerated() {
            for clip in section.clips {
                let place = "\(book), section \(number + 1), “\(section.title)”: \(clip.file) from \(clip.startTime) to \(clip.endTime) s"
                guard let length = lengths[clip.file] else {
                    XCTFail("\(place): its file was not measured", line: line)
                    continue
                }
                XCTAssertGreaterThanOrEqual(clip.startTime, 0, "\(place) starts before its file", line: line)
                XCTAssertLessThan(clip.startTime, length, "\(place) starts past its file's end, \(length) s", line: line)
                XCTAssertGreaterThan(clip.endTime, clip.startTime, "\(place) plays nothing", line: line)
                XCTAssertLessThanOrEqual(clip.endTime, length + Self.rounding, "\(place) ends past its file's end, \(length) s", line: line)
            }
        }
    }

    /// Fails where the clips of `sections`, one after another, do not play
    /// the book in reading order: each file once, the files in the order
    /// of their names (both books number their recordings in the order
    /// their NCC and spine read them), and within a file each clip starting
    /// where the one before it ended or later.
    private func assertInReadingOrder(_ sections: [AudioSegment], book: String, line: UInt) {
        var filesPlayed: [String] = []
        var endOfLastClip: TimeInterval = 0
        for (number, section) in sections.enumerated() {
            for clip in section.clips {
                let place = "\(book), section \(number + 1), “\(section.title)”: \(clip.file) from \(clip.startTime) s"
                if clip.file != filesPlayed.last {
                    XCTAssertFalse(filesPlayed.contains(clip.file), "\(place) returns to a file it left", line: line)
                    filesPlayed.append(clip.file)
                } else {
                    XCTAssertGreaterThanOrEqual(
                        clip.startTime,
                        endOfLastClip - Self.rounding,
                        "\(place) starts before the clip before it ended, at \(endOfLastClip) s",
                        line: line
                    )
                }
                endOfLastClip = clip.endTime
            }
        }
        XCTAssertEqual(filesPlayed, filesPlayed.sorted(), "\(book) plays its files out of the order of their names", line: line)
    }

    /// The clip layout of `sections`, one line per section: its number,
    /// then each clip as its file and its start and end in seconds, to the
    /// millisecond, as Fire Safety's third section is written:
    /// "3: 03_Contents_of_this_DAISY_book.mp3 0.000-60.950".
    static func layout(of sections: [AudioSegment]) -> String {
        sections.enumerated().map { number, section in
            "\(number + 1): " + section.clips.map { clip in
                "\(clip.file) " + String(format: "%.3f-%.3f", clip.startTime, clip.endTime)
            }.joined(separator: ", ") + "\n"
        }.joined()
    }
}
