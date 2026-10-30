import AVFoundation
import os
import XCTest
@testable import TextMouth

/// A speech export's chapter files joined into one audio file (FMT43): three
/// spoken chapters, each a 16-bit CAF of its own, become an M4B, an M4A, or
/// an MP3 through the audio editor's renderer, with a chapter at each file's
/// start, read back as the app reads chapters, and the export's title and
/// artist tags; a chapter with no sound is left out; the progress climbs to
/// the end; Stop ends an encode before or while it runs, leaving nothing at
/// its destination; chapters that can't be joined are refused; the formats
/// the Export dialog offers; and the editor's timeline that joins the files.
///
/// Every file is written in a sandbox folder of the test's own and read
/// back, never played.
final class SpeechExportEncoderTests: XCTestCase {

    /// Frames a second of the chapter files, as speech is rendered.
    private static let rate = 22_050.0

    /// The chapters most tests join: each one's title, and how long its file
    /// lasts, in seconds.
    private static let chapters: [(title: String, seconds: Double)] = [
        (title: "Harbour", seconds: 1.0),
        (title: "Market", seconds: 1.5),
        (title: "Evening", seconds: 0.5),
    ]

    /// The chapters the Stop test joins: twelve seconds in all, so the
    /// render tells its progress many times over before its end.
    private static let longChapters: [(title: String, seconds: Double)] = [
        (title: "Harbour", seconds: 4),
        (title: "Market", seconds: 4),
        (title: "Evening", seconds: 4),
    ]

    /// The title of the book the chapters come from, which a render gives
    /// the sound before the first marker.
    private static let bookTitle = "The Ferry Timetable"

    /// The tags every encode gives its file: the book's title and author.
    private static let metadata = AudioRenderMetadata(title: bookTitle, author: "Odile Marchetti")

    // MARK: - Joining Files on the Timeline

    /// The three files are laid out one after another, each played whole
    /// from its first frame as processed sound by its name, with a marker at
    /// the start of each: at 0, at the first file's length, and at the first
    /// two files' lengths.
    func testJoiningLaysTheFilesOutOneAfterAnotherWithAMarkerAtEachStart() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: Self.joined(Self.chapters))

        XCTAssertEqual(timeline.sampleRate, Self.rate)
        XCTAssertEqual(timeline.segments, [
            AudioEditTimeline.Segment(source: .processed("0000.caf"), sourceStart: 0, length: 22_050),
            AudioEditTimeline.Segment(source: .processed("0001.caf"), sourceStart: 0, length: 33_075),
            AudioEditTimeline.Segment(source: .processed("0002.caf"), sourceStart: 0, length: 11_025),
        ])
        XCTAssertEqual(timeline.chapters, [
            AudioEditTimeline.Chapter(frame: 0, title: "Harbour"),
            AudioEditTimeline.Chapter(frame: 22_050, title: "Market"),
            AudioEditTimeline.Chapter(frame: 55_125, title: "Evening"),
        ])
        XCTAssertEqual(timeline.length, 66_150)
        XCTAssertEqual(timeline.duration, 3)
    }

    /// A file of no frames, or fewer, has no sound to mark: it is left out,
    /// and its marker with it, even when the file after it has no marker of
    /// its own to take that frame, or there is no file after it at all.
    func testJoiningLeavesOutAFileOfNoFramesWithItsMarker() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [
            (name: "0000.caf", frames: 0, title: "Opening"),
            (name: "0001.caf", frames: 22_050, title: nil),
            (name: "0002.caf", frames: 0, title: "Interval"),
            (name: "0003.caf", frames: -5, title: "Nowhere"),
            (name: "0004.caf", frames: 11_025, title: "Evening"),
            (name: "0005.caf", frames: 0, title: "Coda"),
        ])

        XCTAssertEqual(timeline.segments, [
            AudioEditTimeline.Segment(source: .processed("0001.caf"), sourceStart: 0, length: 22_050),
            AudioEditTimeline.Segment(source: .processed("0004.caf"), sourceStart: 0, length: 11_025),
        ])
        XCTAssertEqual(timeline.chapters, [AudioEditTimeline.Chapter(frame: 22_050, title: "Evening")])
        XCTAssertEqual(timeline.length, 33_075)
    }

    /// A file without a title has no marker: its sound belongs to the
    /// chapter before it, or, ahead of every marker, to the chapter a render
    /// names after the book.
    func testJoiningGivesAFileWithoutATitleNoMarker() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [
            (name: "0000.caf", frames: 11_025, title: nil),
            (name: "0001.caf", frames: 22_050, title: "Harbour"),
            (name: "0002.caf", frames: 33_075, title: nil),
            (name: "0003.caf", frames: 11_025, title: "Evening"),
        ])

        XCTAssertEqual(timeline.segments.map(\.source), ["0000.caf", "0001.caf", "0002.caf", "0003.caf"].map(AudioEditTimeline.Source.processed))
        XCTAssertEqual(timeline.chapters, [
            AudioEditTimeline.Chapter(frame: 11_025, title: "Harbour"),
            AudioEditTimeline.Chapter(frame: 66_150, title: "Evening"),
        ])
        XCTAssertEqual(
            AudioEditRenderer.chapterList(of: timeline, leadingTitle: Self.bookTitle).map(\.title),
            [Self.bookTitle, "Harbour", "Evening"]
        )
    }

    /// Joining no files gives no sound and no markers.
    func testJoiningNoFilesGivesNoSound() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: [])

        XCTAssertEqual(timeline.segments, [])
        XCTAssertEqual(timeline.chapters, [])
        XCTAssertEqual(timeline.length, 0)
    }

    /// The chapter list a render writes for the joined files has a chapter
    /// for each titled file, the first at 0, each lasting as long as its
    /// file; the book's title names none, as no sound comes before the
    /// first marker.
    func testTheChapterListOfJoinedFilesHasAChapterForEachTitledFile() {
        let timeline = AudioEditTimeline(sampleRate: Self.rate, joining: Self.joined(Self.chapters))

        XCTAssertEqual(AudioEditRenderer.chapterList(of: timeline, leadingTitle: Self.bookTitle), [
            AudioRenderChapter(start: 0, duration: 1, title: "Harbour"),
            AudioRenderChapter(start: 1, duration: 1.5, title: "Market"),
            AudioRenderChapter(start: 2.5, duration: 0.5, title: "Evening"),
        ])
    }

    // MARK: - Joining Chapters into One File

    /// Three chapters become an M4B audiobook of AAC, with a chapter at each
    /// file's start, titled as given, lasting as long as the three, and
    /// tagged with the export's title and artist.
    func testThreeChaptersBecomeAnM4BWithAChapterAtEachFilesStart() async throws {
        try await assertJoinsTheThreeChapters(into: .m4b, storedAs: kAudioFormatMPEG4AAC)
    }

    /// The same three chapters become an M4A of AAC in the same way.
    func testThreeChaptersBecomeAnM4AWithAChapterAtEachFilesStart() async throws {
        try await assertJoinsTheThreeChapters(into: .m4a, storedAs: kAudioFormatMPEG4AAC)
    }

    /// The same three chapters become an MP3, whose ID3 chapter frames read
    /// back in the same way.
    func testThreeChaptersBecomeAnMP3WithAChapterAtEachFilesStart() async throws {
        try await assertJoinsTheThreeChapters(into: .mp3, storedAs: kAudioFormatMPEGLayer3)
    }

    /// A chapter whose file holds no sound is left out of the file, its
    /// chapter with it, even the first, which then can't stand for the
    /// audio the others share: the next chapter starts at 0.
    func testAChapterWithNoSoundIsLeftOut() async throws {
        let export = try makeExport([(title: "Opening", seconds: 0)] + Self.chapters, format: .m4b)

        try await encode(export, as: .m4b)

        let chapters = await AudioPlaybackService.extractChapters(from: export.destination)
        XCTAssertEqual(chapters.map(\.title), ["Harbour", "Market", "Evening"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 1, 2.5], accuracy: 0.02)
        let duration = try await AVURLAsset(url: export.destination).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.1)
    }

    // MARK: - Progress

    /// An encode tells how far it has come, in every format: never going
    /// back, and ending at about the end.
    func testAnEncodeReportsItsProgressUpToTheEnd() async throws {
        for format in SpeechExportFormat.allCases {
            let export = try makeExport(Self.chapters, format: format)
            let reports = ProgressReports()

            try await encode(export, as: format, progress: { reports.add($0) })

            let values = reports.values
            XCTAssertFalse(values.isEmpty, "\(format): no progress was told")
            XCTAssertEqual(values, values.sorted(), "\(format): the progress went back")
            XCTAssertTrue(values.allSatisfy { (0...1).contains($0) }, "\(format): \(values)")
            XCTAssertEqual(try XCTUnwrap(values.last, "\(format)"), 1, accuracy: 0.01, "\(format)")
        }
    }

    // MARK: - Stop

    /// An encode whose token is already cancelled throws `CancellationError`
    /// at once: nothing is written, and no progress is told.
    func testAnEncodeStoppedBeforeItStartsWritesNothing() async throws {
        let export = try makeExport(Self.chapters, format: .m4b)
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let reports = ProgressReports()

        do {
            try await encode(export, as: .m4b, cancellation: cancellation, progress: { reports.add($0) })
            XCTFail("a stopped encode ran")
        } catch is CancellationError {
            // Stopped, as it should be.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.destination.path))
        XCTAssertEqual(reports.values, [])
    }

    /// Stop while an encode runs ends it, in every format: once the progress
    /// passes a fifth, the token is cancelled, and the render, held there as
    /// a long book's would still be running, is cancelled in turn by the
    /// encoder's watch. The encode throws `CancellationError`, its progress
    /// stops short of the end, and nothing is left at the destination.
    func testStopWhileAnEncodeRunsEndsItAndLeavesNothing() async throws {
        for format in SpeechExportFormat.allCases {
            let export = try makeExport(Self.longChapters, format: format)
            let cancellation = BookExportCancellation()
            let reports = ProgressReports()
            // Whether the render's task was cancelled while it was held.
            let renderWasCancelled = OSAllocatedUnfairLock(initialState: false)

            do {
                try await encode(export, as: format, cancellation: cancellation) { value in
                    reports.add(value)
                    guard value > 0.2, !cancellation.isCancelled else { return }
                    cancellation.cancel()
                    let cancelled = holdUntilTheTaskIsCancelled()
                    renderWasCancelled.withLock { $0 = cancelled }
                }
                XCTFail("\(format): the encode ran to its end after Stop")
            } catch is CancellationError {
                // Stopped, as it should be.
            }

            XCTAssertTrue(renderWasCancelled.withLock { $0 }, "\(format): the encoder's watch never cancelled the render")
            XCTAssertLessThan(try XCTUnwrap(reports.values.last, "\(format)"), 1, "\(format): the render ran to its end")
            XCTAssertFalse(FileManager.default.fileExists(atPath: export.destination.path), "\(format): a file was left")
        }
    }

    // MARK: - Chapters That Can't Be Joined

    /// Chapters whose files differ in sample rate, or in channels, can't be
    /// one file's sound: the encode is refused before anything is written.
    func testChaptersWhoseAudioDiffersAreRefused() async throws {
        for (rate, channels) in [(16_000.0, AVAudioChannelCount(1)), (Self.rate, AVAudioChannelCount(2))] {
            let (folder, destination) = try makeFolders(for: .m4b)
            try writeChapterFile("0000.caf", seconds: 1, in: folder)
            try writeChapterFile("0001.caf", seconds: 1, in: folder, sampleRate: rate, channels: channels)
            let export = PreparedExport(
                files: [
                    SpeechExportChapterFile(name: "0000.caf", title: "Harbour"),
                    SpeechExportChapterFile(name: "0001.caf", title: "Market"),
                ],
                folder: folder,
                destination: destination
            )

            await assertRefused(export, with: .renderFailed("the chapters' audio differs"), "\(rate) Hz, \(channels) channels")
        }
    }

    /// A name that is not a plain file name is refused before any file is
    /// opened, even when there is a file there to read: a chapter's file is
    /// always one in the folder itself.
    func testANameThatIsNotAPlainFileNameIsRefused() async throws {
        let (folder, destination) = try makeFolders(for: .m4b)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeChapterFile("0000.caf", seconds: 1, in: folder)
        try writeChapterFile("0001.caf", seconds: 1, in: nested)
        try writeChapterFile("Outside.caf", seconds: 1, in: folder.deletingLastPathComponent())

        for name in ["../Outside.caf", "Nested/0001.caf", "..", ".", ""] {
            let export = PreparedExport(
                files: [
                    SpeechExportChapterFile(name: "0000.caf", title: "Harbour"),
                    SpeechExportChapterFile(name: name, title: "Market"),
                ],
                folder: folder,
                destination: destination
            )

            await assertRefused(export, with: .fileOutsidePackage, "“\(name)”")
        }
    }

    /// No chapters make no file: the encode is refused.
    func testNoChaptersAreRefused() async throws {
        let (folder, destination) = try makeFolders(for: .m4b)

        await assertRefused(PreparedExport(files: [], folder: folder, destination: destination), with: .renderFailed("no chapters"))
    }

    /// Chapters whose files hold no sound at all make no file: the encode is
    /// refused.
    func testChaptersWithNoSoundAtAllAreRefused() async throws {
        let export = try makeExport([(title: "Harbour", seconds: 0), (title: "Market", seconds: 0)], format: .m4b)

        await assertRefused(export, with: .renderFailed("the chapters hold no sound"))
    }

    /// A chapter's file that is missing, or holds no audio, is refused as
    /// audio that couldn't be read.
    func testAMissingOrUnreadableChapterFileIsRefused() async throws {
        let (folder, destination) = try makeFolders(for: .m4b)
        try writeChapterFile("0000.caf", seconds: 1, in: folder)
        try Data("Not a sound in it.".utf8).write(to: folder.appendingPathComponent("0001.caf"))

        for name in ["0001.caf", "0002.caf"] {
            let export = PreparedExport(
                files: [
                    SpeechExportChapterFile(name: "0000.caf", title: "Harbour"),
                    SpeechExportChapterFile(name: name, title: "Market"),
                ],
                folder: folder,
                destination: destination
            )

            await assertRefused(export, with: .unreadableAudio, name)
        }
    }

    // MARK: - The Formats

    /// The formats the Export dialog offers, in its order, M4B first as its
    /// default: each named in the audio editor's words, with its file's
    /// extension, and written by the renderer as the editor's format of the
    /// same name. All three are offered, as the LAME built into TextMouth
    /// writes MP3.
    func testTheFormatsTheDialogOffers() {
        let formats = SpeechExportFormat.allCases

        XCTAssertEqual(formats, [.m4b, .m4a, .mp3])
        XCTAssertEqual(formats.map(\.rawValue), ["m4b", "m4a", "mp3"])
        XCTAssertEqual(formats.map(\.title), ["M4B Audiobook (AAC)", "M4A (AAC)", "MP3"])
        XCTAssertEqual(formats.map(\.fileExtension), ["m4b", "m4a", "mp3"])
        XCTAssertEqual(formats.map(\.exportFormat), [.m4b, .m4a, .mp3])
        XCTAssertEqual(formats.map(\.exportFormat.renderFormat), [.aacM4B, .aacM4A, .mp3])
        XCTAssertTrue(MP3Encoder.isAvailable)
        XCTAssertEqual(SpeechExportFormat.available, [.m4b, .m4a, .mp3])
    }

    // MARK: - Helpers

    /// A speech export ready to encode: its chapters' files, the folder they
    /// are in, and where the joined file goes.
    private struct PreparedExport {
        /// The chapters' files, in order.
        let files: [SpeechExportChapterFile]
        /// The folder holding them.
        let folder: URL
        /// Where the joined file goes, beside the folder.
        let destination: URL
    }

    /// Joins the three chapters into a file of `format` and checks it: its
    /// chapters, read back as the app reads them, are the three titles,
    /// starting where each file does, at 0, 1, and 2.5 seconds; it lasts as
    /// long as the three, 3 seconds; its sound is stored as `codec`; and its
    /// title and artist tags are the export's.
    private func assertJoinsTheThreeChapters(
        into format: SpeechExportFormat,
        storedAs codec: AudioFormatID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let export = try makeExport(Self.chapters, format: format)

        try await encode(export, as: format)

        let chapters = await AudioPlaybackService.extractChapters(from: export.destination)
        XCTAssertEqual(chapters.map(\.title), ["Harbour", "Market", "Evening"], file: file, line: line)
        XCTAssertEqual(chapters.map(\.startTime), [0, 1, 2.5], accuracy: 0.02, file: file, line: line)
        let asset = AVURLAsset(url: export.destination, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tags) = try await asset.load(.duration, .commonMetadata)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1, file: file, line: line)
        let track = try await asset.loadTracks(withMediaType: .audio).first
        let stored = try await track?.load(.formatDescriptions).first?.audioStreamBasicDescription
        XCTAssertEqual(stored?.mFormatID, codec, file: file, line: line)
        let title = try await AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .commonIdentifierTitle)
            .first?.load(.stringValue)
        let artist = try await AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .commonIdentifierArtist)
            .first?.load(.stringValue)
        XCTAssertEqual(title, Self.metadata.title, file: file, line: line)
        XCTAssertEqual(artist, Self.metadata.author, file: file, line: line)
    }

    /// Encodes `export` and checks that the encode is refused with
    /// `expected` before anything is written: no file at its destination,
    /// and no progress told.
    private func assertRefused(
        _ export: PreparedExport,
        with expected: AudioEditError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reports = ProgressReports()
        do {
            try await encode(export, as: .m4b, progress: { reports.add($0) })
            XCTFail("the encode was not refused: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AudioEditError, expected, message, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.destination.path), message, file: file, line: line)
        XCTAssertEqual(reports.values, [], message, file: file, line: line)
    }

    /// Encodes `export`'s chapters into its destination as `format`, tagged
    /// with `metadata`, as the export does: on a background queue, which the
    /// encode blocks, while the test waits without blocking a thread.
    private func encode(
        _ export: PreparedExport,
        as format: SpeechExportFormat,
        cancellation: BookExportCancellation = BookExportCancellation(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let metadata = Self.metadata
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try SpeechExportEncoder.encode(
                        export.files,
                        in: export.folder,
                        format: format,
                        metadata: metadata,
                        to: export.destination,
                        cancellation: cancellation,
                        progress: progress
                    )
                })
            }
        }
    }

    /// A new folder of chapter files in a sandbox of this test's own, one
    /// file for each of `chapters`, named for its place
    /// (`writeChapterFile`), and where the joined file of `format` goes.
    private func makeExport(_ chapters: [(title: String, seconds: Double)], format: SpeechExportFormat) throws -> PreparedExport {
        let (folder, destination) = try makeFolders(for: format)
        let files = try chapters.enumerated().map { index, chapter in
            let name = Self.fileName(index)
            try writeChapterFile(name, seconds: chapter.seconds, in: folder)
            return SpeechExportChapterFile(name: name, title: chapter.title)
        }
        return PreparedExport(files: files, folder: folder, destination: destination)
    }

    /// A new, empty folder for chapter files in a sandbox of this test's own,
    /// removed when the test ends, and where a joined file of `format` goes,
    /// beside the folder.
    private func makeFolders(for format: SpeechExportFormat) throws -> (folder: URL, destination: URL) {
        let sandbox = try makeSandboxDirectory("SpeechExportEncoder")
        let folder = sandbox.appendingPathComponent("Chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, sandbox.appendingPathComponent("\(Self.bookTitle).\(format.fileExtension)"))
    }

    /// Writes a chapter's file as the export keeps its speech: a 16-bit
    /// integer linear PCM CAF of `channels` channels at `sampleRate`, holding
    /// a quiet 440 Hz tone `seconds` long, or no sound for 0, named `name` in
    /// `folder`. It is never played.
    private func writeChapterFile(
        _ name: String,
        seconds: Double,
        in folder: URL,
        sampleRate: Double = SpeechExportEncoderTests.rate,
        channels: AVAudioChannelCount = 1
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The file is closed, and its header finished, when `file` goes as
        // this returns.
        let file = try AVAudioFile(
            forWriting: folder.appendingPathComponent(name),
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        guard frames > 0 else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        let samples = try XCTUnwrap(buffer.int16ChannelData)
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            // A tenth of full scale.
            let value = Int16((sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 3_277).rounded())
            for channel in 0..<Int(channels) {
                samples[channel][frame] = value
            }
        }
        try file.write(from: buffer)
    }

    /// The name of the file of the chapter at `index`, as the export's store
    /// names them: "0000.caf", "0001.caf", and on.
    private static func fileName(_ index: Int) -> String {
        String(format: "%04d.caf", index)
    }

    /// `chapters` as the timeline joins their files: each named for its
    /// place, as many frames long as its seconds hold, and titled.
    private static func joined(_ chapters: [(title: String, seconds: Double)]) -> [(name: String, frames: Int64, title: String?)] {
        chapters.enumerated().map { index, chapter in
            (name: fileName(index), frames: Int64((chapter.seconds * rate).rounded()), title: chapter.title)
        }
    }
}

/// Holds the task that calls it, a render telling its progress, until the
/// task is cancelled or five seconds have passed; true when it was
/// cancelled. A short book's render would otherwise reach its end before the
/// encoder's watch, which looks at the token every tenth of a second, saw
/// Stop; a long book's would still be running.
private func holdUntilTheTaskIsCancelled() -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !Task.isCancelled {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// The progress an encode told, handed from its thread to the test.
private final class ProgressReports: Sendable {
    /// The values, behind a lock.
    private let stored = OSAllocatedUnfairLock<[Double]>(initialState: [])

    /// Every value told, in order.
    var values: [Double] {
        stored.withLock { $0 }
    }

    /// Keeps `value`.
    func add(_ value: Double) {
        stored.withLock { $0.append(value) }
    }
}

/// `XCTAssertEqual` for lists of times, each to within `accuracy`.
private func XCTAssertEqual(
    _ found: [TimeInterval],
    _ expected: [TimeInterval],
    accuracy: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard found.count == expected.count else {
        return XCTFail("\(found) has \(found.count) times, not \(expected.count)", file: file, line: line)
    }
    for (value, wanted) in zip(found, expected) {
        XCTAssertEqual(value, wanted, accuracy: accuracy, "\(found)", file: file, line: line)
    }
}
