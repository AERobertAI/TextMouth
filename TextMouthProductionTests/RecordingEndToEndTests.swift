import AVFoundation
import XCTest
@testable import TextMouth

/// Recording from end to end (FR04): a take recorded in the Record window,
/// with a recorder that needs no microphone, is saved through the library's
/// own import into a playable audiobook that keeps its take, and the take
/// leaves on the policy's schedule while the book plays on; a take cut off
/// as a crash cuts one off is still saved; and, only when asked for, a few
/// seconds from this Mac's own microphone are recorded as 16-bit mono PCM.
/// Nothing is played aloud. Each test saves into a library folder of its
/// own and puts the library index back afterwards.
final class RecordingEndToEndTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder this test saves into.
    private var folderPath = ""

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "Recording End to End \(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - From the Window to the Library

    /// A take recorded in the Record window is saved through the library
    /// into the folder chosen: the book is in the library, plays for the
    /// take's length, and keeps the take, and the Recordings folder is left
    /// empty. A day later the policy's sweep removes the take, and the book
    /// still plays.
    @MainActor
    func testARecordingBecomesABookAndItsTakeLeavesOnSchedule() async throws {
        let takes = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let backend = FakeCaptureBackend(sampleRate: 24_000)
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library()
        let store = makeSandboxedPreferences("recording-end-to-end")
        let folderPath = self.folderPath
        let model = RecordingWindowModel(
            service: RecordingService(
                backend: backend,
                permission: FakeMicrophonePermission(.authorized).permission,
                takesFolder: takes,
                pollInterval: nil
            ),
            catalog: FakeRecordingInputCatalog([TestMicrophones.builtIn]),
            store: store,
            saver: RecordingWindowModel.librarySaver(library),
            folderPaths: { [folderPath] },
            announce: { _ in },
            openBook: { _ in },
            announcementLead: .zero
        )
        model.title = "Ridge Survey: Day 2"
        model.folderPath = folderPath

        await model.record()
        await backend.record(seconds: 3)
        await model.stop()

        guard case .saved(let book) = model.phase else {
            return XCTFail("the recording was not saved: \(model.phase)")
        }
        XCTAssertEqual(library.library.books.map(\.id), [book.id])
        XCTAssertEqual(book.folderPath, folderPath)
        XCTAssertEqual(book.format, .audio)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: takes.path), [], "the Recordings folder kept files")
        let package = book.tmbDirectory
        let take = package.appendingPathComponent(BookOrigin.originalTakeFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.path))
        let origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        XCTAssertEqual(origin.inputDeviceName, "MacBook Air Microphone")
        XCTAssertEqual(origin.duration, 3, accuracy: 0.01)
        let audio = AVURLAsset(url: book.bookFileURL)
        let playable = try await audio.load(.isPlayable)
        XCTAssertTrue(playable)
        let length = try await audio.load(.duration).seconds
        XCTAssertEqual(length, 3, accuracy: 0.1)

        // A day after saving, the standard policy's day is up.
        let swept = expectation(description: "the sweep finished")
        swept.assertForOverFulfill = false
        let dayLater = try XCTUnwrap(origin.originalTake?.lastEditedAt).addingTimeInterval(24 * 60 * 60 + 1)
        library.sweepAudioOriginalsInBackground(now: dayLater) { _ in swept.fulfill() }
        await fulfillment(of: [swept], timeout: 20)

        XCTAssertFalse(FileManager.default.fileExists(atPath: take.path), "the take outlived its day")
        XCTAssertNil(try BookOrigin.load(fromPackage: package)?.originalTake)
        let stillPlayable = try await AVURLAsset(url: book.bookFileURL).load(.isPlayable)
        XCTAssertTrue(stillPlayable)
    }

    // MARK: - A Take Cut Off

    /// A take cut off before its file was finished, as a crash or a power
    /// loss leaves one, its audio size never written, still reads to its
    /// full length and still becomes a book's audio: the reason takes are
    /// 16-bit PCM in a CAF file.
    func testATakeCutOffBeforeItsFileWasFinishedIsStillSaved() async throws {
        let takes = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let take = takes.appendingPathComponent("Cut Off.caf")
        try RecordingAudioFixtures.writeTake(to: take, duration: 3)
        try Self.forgetAudioSize(of: take)

        XCTAssertEqual(try XCTUnwrap(RecordingTakeFiles.duration(of: take)), 3, accuracy: 0.01)
        let encoded = takes.appendingPathComponent("Cut Off.m4a")
        try await RecordingEncoder.encode(take: take, to: encoded, title: "Cut Off")
        let length = try await AVURLAsset(url: encoded).load(.duration).seconds
        XCTAssertEqual(length, 3, accuracy: 0.1)
    }

    // MARK: - This Mac's Microphone (opt-in)

    /// Records a few seconds from this Mac's default microphone, with a
    /// pause, through AVFoundation's capture session, and checks the take:
    /// 16-bit integer PCM, one channel, as long as was recorded, the levels
    /// read while recording. Run only when asked
    /// (TEST_RUNNER_TEXTMOUTH_MICROPHONE=1), since it records the room and
    /// may show macOS's microphone prompt the first time.
    @MainActor
    func testThisMacsMicrophoneRecordsSixteenBitMonoPCM() async throws {
        guard ProcessInfo.processInfo.environment[AudioInputPermission.microphoneTestVariable] == "1" else {
            throw XCTSkip("Records from this Mac's microphone only when run with TEST_RUNNER_TEXTMOUTH_MICROPHONE=1")
        }
        let catalog = SystemRecordingInputCatalog()
        guard let device = RecordingInputChoice.resolve(
            remembered: "",
            among: catalog.devices(),
            systemDefault: catalog.systemDefaultDeviceID()
        ).device else {
            throw XCTSkip("No microphone is connected")
        }
        let service = RecordingService(
            backend: CaptureSessionRecordingBackend(),
            permission: .system,
            takesFolder: try RecordingAudioFixtures.makeTakesFolder(for: self)
        )

        await service.start(from: device)
        guard service.state == .recording else {
            return XCTFail("recording from \(device.name) did not start: \(service.state)")
        }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertNotNil(service.levels, "no levels were read")
        await service.pause()
        try await Task.sleep(for: .seconds(1))
        await service.resume()
        try await Task.sleep(for: .seconds(1.5))
        await service.stop()

        guard case .finished(let take) = service.state else {
            return XCTFail("the take did not finish: \(service.state)")
        }
        defer { RecordingTakeFiles.remove(take.url) }
        let file = try AVAudioFile(forReading: take.url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(take.duration, 3, accuracy: 0.5, "the pause was recorded, or the take was cut short")
    }

    // MARK: - Helpers

    /// Makes the CAF file at `url` look as a recording cut off leaves one:
    /// its audio data chunk's size is -1, "unknown", as CAF writes it until
    /// the file is finished, so the audio runs to the end of the file. A
    /// CAF file is an 8-byte header and chunks, each a 4-byte type, an
    /// 8-byte big-endian size, and its content.
    private static func forgetAudioSize(of url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        var offset = 8
        while offset + 12 <= bytes.count {
            let type = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            if type == "data" {
                bytes.replaceSubrange((offset + 4)..<(offset + 12), with: [UInt8](repeating: 0xFF, count: 8))
                try Data(bytes).write(to: url)
                return
            }
            let size = bytes[(offset + 4)..<(offset + 12)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size < UInt64(bytes.count) else { break }
            offset += 12 + Int(size)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
