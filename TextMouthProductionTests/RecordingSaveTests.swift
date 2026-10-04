import AVFoundation
import XCTest
@testable import TextMouth

/// Saving a take as an audiobook (FR04): the take is encoded as mono AAC in
/// an M4A file tagged with its title, at a bit rate suited to speech, and
/// imported through the staged import into a new package that holds the
/// book's audio, the original take while the policy keeps it, and the
/// book's origin record. The audio is checked by reading it, never played.
/// Each test imports into a library folder of its own and puts the library
/// index back afterwards.
final class RecordingSaveTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder this test saves into.
    private var folderPath = ""
    /// Where this test's takes are written, outside the library.
    private var takes: URL?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "Recording Save \(UUID().uuidString.prefix(8))"
        takes = try RecordingAudioFixtures.makeTakesFolder(for: self)
    }

    override func tearDownWithError() throws {
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - Encoding

    /// A take, at the rates a Mac's microphone (48 kHz), AirPods (24 kHz),
    /// and a low-rate microphone record, becomes one channel of AAC in an
    /// M4A file of the same length, tagged with its title, and playable.
    func testATakeIsEncodedAsMonoAACTaggedWithItsTitle() async throws {
        for rate in [8_000.0, 24_000, 48_000] {
            let take = try Self.makeTake(seconds: 2, sampleRate: rate, in: XCTUnwrap(takes))
            let encoded = take.deletingPathExtension().appendingPathExtension("m4a")

            try await RecordingEncoder.encode(take: take, to: encoded, title: "Trail Notes at \(Int(rate))")

            let asset = AVURLAsset(url: encoded)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 2, accuracy: 0.1, "\(rate) Hz")
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, "\(rate) Hz")
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first?.audioStreamBasicDescription)
            XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC, "\(rate) Hz")
            XCTAssertEqual(format.mChannelsPerFrame, 1, "\(rate) Hz")
            XCTAssertEqual(format.mSampleRate, rate, "\(rate) Hz")
            let titles = AVMetadataItem.metadataItems(
                from: try await asset.load(.commonMetadata),
                filteredByIdentifier: .commonIdentifierTitle
            )
            let title = try await titles.first?.load(.stringValue)
            XCTAssertEqual(title, "Trail Notes at \(Int(rate))")
        }
    }

    /// Speech is encoded at 64 kbit/s, or at the most the AAC encoder
    /// accepts at a low sample rate (measured on macOS 26: 24 kbit/s at
    /// 8 kHz, 48 at 16 kHz), and at a sample rate AAC takes.
    func testTheEncodingSuitsSpeech() {
        XCTAssertEqual(RecordingEncoder.bitRate(forSampleRate: 48_000), 64_000)
        XCTAssertEqual(RecordingEncoder.bitRate(forSampleRate: 44_100), 64_000)
        XCTAssertEqual(RecordingEncoder.bitRate(forSampleRate: 24_000), 64_000)
        XCTAssertEqual(RecordingEncoder.bitRate(forSampleRate: 16_000), 48_000)
        XCTAssertEqual(RecordingEncoder.bitRate(forSampleRate: 8_000), 24_000)
        XCTAssertEqual(RecordingEncoder.outputSampleRate(for: 48_000), 48_000)
        XCTAssertEqual(RecordingEncoder.outputSampleRate(for: 96_000), 48_000)
        XCTAssertEqual(RecordingEncoder.outputSampleRate(for: 44_100), 44_100)
        XCTAssertEqual(RecordingEncoder.outputSampleRate(for: 30_000), 24_000)
        XCTAssertEqual(RecordingEncoder.outputSampleRate(for: 4_000), 8_000)
    }

    /// A file that is not audio is not encoded, and nothing is left behind.
    func testAFileThatIsNotATakeIsNotEncoded() async throws {
        let notATake = try XCTUnwrap(takes).appendingPathComponent("Not a take.caf")
        try AudioTestFixtures.writeNonAudioBytes(to: notATake)
        let encoded = try XCTUnwrap(takes).appendingPathComponent("Not a take.m4a")

        do {
            try await RecordingEncoder.encode(take: notATake, to: encoded, title: "Nothing")
            XCTFail("a file that is not audio was encoded")
        } catch {
            XCTAssertEqual(error as? RecordingEncodingError, .unreadableTake)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: encoded.path))
    }

    // MARK: - The Package

    /// A recording becomes one published audiobook: its package holds the
    /// encoded audio under its title, the take as original-take.caf, and
    /// the origin record naming both, and the book reads as audio of the
    /// take's length. The files given stay where they were.
    func testARecordingBecomesAnAudiobookKeepingItsTake() async throws {
        let (take, encoded) = try await Self.makeEncodedTake(title: "Morning Notes: Day 3", in: XCTUnwrap(takes))
        let origin = Self.origin(keepingTake: true)

        let imported = try FileImportService.importRecording(
            audio: encoded,
            take: take,
            origin: origin,
            title: "Morning Notes: Day 3",
            toFolder: folderPath
        )

        let book = imported.book
        XCTAssertEqual(book.title, "Morning Notes: Day 3")
        XCTAssertEqual(book.author, "Unknown")
        XCTAssertEqual(book.format, .audio)
        XCTAssertEqual(book.folderPath, folderPath)
        XCTAssertEqual(URL(fileURLWithPath: book.filePath).lastPathComponent, "Morning Notes- Day 3.m4a")
        XCTAssertEqual(try XCTUnwrap(book.audioDuration), 2, accuracy: 0.1)
        let package = book.tmbDirectory
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: package.path)),
            ["Morning Notes- Day 3.m4a", "original-take.caf", "origin.json", "bookInfo.json", "contentIndex.json"]
        )
        XCTAssertEqual(try BookOrigin.load(fromPackage: package), origin)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("original-take.caf")), try Data(contentsOf: take))
        let record = try BookInfo.load(from: package)
        XCTAssertEqual(record.metadata.format, .audio)
        XCTAssertEqual(record.metadata.title, "Morning Notes: Day 3")
        XCTAssertNotNil(record.contentIndex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.path), "the take was moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encoded.path))
    }

    /// A recording's origin record and original take are never taken for
    /// the book itself: recovering a package whose bookInfo.json is lost
    /// finds the audio alone, and the cloud and DAISY checks of a package's
    /// content pass both by.
    func testARecordingsOwnFilesAreNeverTakenForTheBook() async throws {
        let (take, encoded) = try await Self.makeEncodedTake(title: "Field Notes", in: XCTUnwrap(takes))
        let imported = try FileImportService.importRecording(
            audio: encoded,
            take: take,
            origin: Self.origin(keepingTake: true),
            title: "Field Notes",
            toFolder: folderPath
        )
        let package = imported.book.tmbDirectory
        try FileManager.default.removeItem(at: TextMouthPaths.bookInfoPath(in: package))

        XCTAssertEqual(try FileImportService.retainedContentURL(in: package).lastPathComponent, "Field Notes.m4a")
        XCTAssertFalse(FileImportService.isPackageContentName(BookOrigin.fileName))
        XCTAssertFalse(FileImportService.isPackageContentName(BookOrigin.originalTakeFileName))
        XCTAssertTrue(FileImportService.isPackageContentName("Field Notes.m4a"))
    }

    /// A recording whose policy keeps no original has no take in its
    /// package, and its record says so.
    func testARecordingKeepingNoTakeHasNone() async throws {
        let (_, encoded) = try await Self.makeEncodedTake(title: "Quick Memo", in: XCTUnwrap(takes))
        let origin = Self.origin(keepingTake: false)

        let imported = try FileImportService.importRecording(
            audio: encoded,
            take: nil,
            origin: origin,
            title: "Quick Memo",
            toFolder: folderPath
        )

        let package = imported.book.tmbDirectory
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("original-take.caf").path))
        XCTAssertNil(try BookOrigin.load(fromPackage: package)?.originalTake)
    }

    /// An import that fails publishes nothing, and leaves the take and its
    /// encoding where they were, so nothing recorded is lost.
    func testAFailedSaveKeepsTheTake() async throws {
        let (take, encoded) = try await Self.makeEncodedTake(title: "Lost Thread", in: XCTUnwrap(takes))

        XCTAssertThrowsError(try FileImportService.importRecording(
            audio: encoded,
            take: take,
            origin: Self.origin(keepingTake: true),
            title: "Lost Thread",
            toFolder: folderPath,
            observer: { step, _ in
                if step == .savingRecord { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .savingRecord)
            XCTAssertEqual((error as? ImportFailure)?.fileName, "Lost Thread.m4a")
        }
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encoded.path))
    }

    // MARK: - The Library

    /// Saving a recording through the library queues it like any import,
    /// adds the book to the library, and returns it, with the take in its
    /// package and the origin record naming when it was saved.
    @MainActor
    func testSavingARecordingAddsItsBookToTheLibrary() async throws {
        let (takeURL, encoded) = try await Self.makeEncodedTake(title: "Garden Plans", in: XCTUnwrap(takes))
        let take = RecordedTake(url: takeURL, startedAt: Self.recordedAt, duration: 2, deviceName: "AirPods Pro")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let savedAt = Date(timeIntervalSince1970: 1_791_000_600)

        let book = try await model.saveRecording(
            take,
            encodedAudio: encoded,
            title: "Garden Plans",
            toFolder: folderPath,
            policy: .deleteAfter(days: 1),
            savedAt: savedAt
        )

        XCTAssertEqual(model.library.books.map(\.id), [book.id])
        let origin = try XCTUnwrap(try BookOrigin.load(fromPackage: book.tmbDirectory))
        XCTAssertEqual(origin.inputDeviceName, "AirPods Pro")
        XCTAssertEqual(origin.recordedAt, Self.recordedAt)
        XCTAssertEqual(origin.originalTake?.lastEditedAt, savedAt)
        XCTAssertNil(origin.originalTake?.policyOverride)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.appendingPathComponent("original-take.caf").path))
    }

    // MARK: - Helpers

    /// When the takes in these tests were recorded.
    private static let recordedAt = Date(timeIntervalSince1970: 1_791_000_000)

    /// The origin record of a two-second take from the Mac's microphone,
    /// keeping the take or not.
    private static func origin(keepingTake: Bool) -> BookOrigin {
        BookOrigin(
            kind: .recording,
            recordedAt: recordedAt,
            duration: 2,
            inputDeviceName: "MacBook Air Microphone",
            originalTake: keepingTake
                ? BookOrigin.OriginalTake(fileName: BookOrigin.originalTakeFileName, lastEditedAt: recordedAt.addingTimeInterval(60), policyOverride: nil)
                : nil
        )
    }

    /// A take of `seconds` seconds of tone at `sampleRate` in `folder`, the
    /// test's takes folder. Static, so a test on the main actor can call it
    /// without handing the test case to another context.
    private static func makeTake(seconds: TimeInterval, sampleRate: Double = 8_000, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Take \(UUID().uuidString.prefix(8)).caf")
        try RecordingAudioFixtures.writeTake(to: url, duration: seconds, sampleRate: sampleRate)
        return url
    }

    /// A two-second take in `folder` and its encoding, tagged `title`.
    private static func makeEncodedTake(title: String, in folder: URL) async throws -> (take: URL, encoded: URL) {
        let take = try makeTake(seconds: 2, in: folder)
        let encoded = take.deletingPathExtension().appendingPathExtension("m4a")
        try await RecordingEncoder.encode(take: take, to: encoded, title: title)
        return (take, encoded)
    }
}
