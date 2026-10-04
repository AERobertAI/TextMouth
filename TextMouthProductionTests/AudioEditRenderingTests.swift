import AVFoundation
import os
import XCTest
@testable import TextMouth

/// Rendering edits (FR04), on generated audio whose samples say where they
/// came from (the research prototype's method, `AudioTestFixtures.writeIdentityRamp`):
/// a cut, a move, inserted silence, and a punch-in land on exactly the
/// samples expected, in the preview's composition and in CAF and WAVE files;
/// chapter markers written into M4A and M4B files read back through the
/// app's own parser, an m4b's own chapters following a cut, a ten-minute
/// file's included; a chapter-only edit keeps an m4b's AAC samples as they
/// were; and cuts of linear PCM are copied as stored. No sound is played.
final class AudioEditRenderingTests: XCTestCase {

    /// Frames a second of the audio.
    private static let rate = 8_000.0

    // MARK: - Sample-Exact Edits

    /// The edits the exactness tests make, in order, on 30 seconds of book
    /// ramp with a 2-second take: what each leaves is worked out by hand in
    /// `expectedPieces`.
    private static let edits: [AudioEdit] = [
        .cut(AudioTimeRange(start: 5, end: 7)),
        .move(AudioTimeRange(start: 10, end: 12), to: 2),
        .insertSilence(at: 3, duration: 1),
        .replace(
            AudioTimeRange(start: 20, end: 21),
            with: AudioEditTake(file: "audioEdits/takes/take.caf", range: AudioTimeRange(start: 0, end: 1.5))
        ),
    ]

    /// What the edits leave, piece by piece, as frames of the book's ramp,
    /// of the take's, or silence:
    /// - the cut removes book frames 40,000 to 56,000;
    /// - the move puts book 96,000 to 112,000 (10 to 12 seconds after the
    ///   cut) at 2 seconds;
    /// - the silence goes 8,000 frames into the moved stretch;
    /// - the punch-in replaces book 168,000 to 176,000 with take 0 to 12,000.
    private static let expectedPieces: [(source: AudioTestFixtures.RampSource?, start: Int, length: Int)] = [
        (.book, 0, 16_000),
        (.book, 96_000, 8_000),
        (nil, 0, 8_000),
        (.book, 104_000, 8_000),
        (.book, 16_000, 24_000),
        (.book, 56_000, 40_000),
        (.book, 112_000, 56_000),
        (.take, 0, 12_000),
        (.book, 176_000, 64_000),
    ]

    /// Every sample of the preview's composition comes from exactly where
    /// the edits put it.
    func testEditsLandOnTheExactSampleInThePreview() async throws {
        let (timeline, sources, _) = try await makeEditedTimeline()
        XCTAssertEqual(timeline.length, 236_000)

        let made = try await AudioEditComposition.make(timeline, sources: sources)

        XCTAssertEqual(made.frames, 236_000)
        let samples = try await Self.compositionSamples(made)
        assertMatchesExpectedPieces(samples)
    }

    /// Rendered into CAF and WAVE files, every sample is where the edits put
    /// it too; WAVE, whose writer takes no floats, holds 32-bit integers,
    /// which keep each of these samples exactly.
    func testEditsLandOnTheExactSampleInCAFAndWAVE() async throws {
        let (timeline, sources, folder) = try await makeEditedTimeline()
        for format in [AudioRenderFormat.pcmCAF, .pcmWAV] {
            let output = folder.appendingPathComponent("edited.\(format.fileExtension)")
            let outcome = try await AudioEditRenderer.render(
                timeline,
                sources: sources,
                to: output,
                format: format,
                metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
            )
            XCTAssertFalse(outcome.copiedSamples, "\(format): silence and a take aren't the base's samples")
            assertMatchesExpectedPieces(try AudioTestFixtures.floatSamples(of: output), "\(format)")
        }
    }

    /// The renderer tells how far it has come, from the start to the end.
    func testARenderReportsItsProgress() async throws {
        let (timeline, sources, folder) = try await makeEditedTimeline()
        let reports = ProgressReports()
        _ = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: folder.appendingPathComponent("progress.caf"),
            format: .pcmCAF,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: nil),
            progress: { reports.add($0) }
        )
        let values = reports.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values, values.sorted(), "progress went backwards")
        XCTAssertEqual(try XCTUnwrap(values.last), 1, accuracy: 0.001)
    }

    // MARK: - Chapters

    /// Chapter markers written into an M4A file read back through the app's
    /// parser, each as a heading, with the sound before the first marker
    /// standing as a chapter named after the book.
    func testChaptersWrittenIntoAnM4AReadBackThroughTheParser() async throws {
        let (sources, folder) = try await makeRampSources(seconds: 12)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.setChapter(at: 4, title: "The Weir"))
        try timeline.applyRearranging(.setChapter(at: 8, title: "The Locks"))
        let output = folder.appendingPathComponent("Canal Survey.m4a")

        _ = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: output,
            format: .aacM4A,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: "Ferry Office")
        )

        let content = try await AudioBookParser.parse(url: output)
        XCTAssertEqual(content.chapters.map(\.title), ["Canal Survey", "The Weir", "The Locks"])
        XCTAssertEqual(content.title, "Canal Survey")
        XCTAssertEqual(content.author, "Ferry Office")
        let chapters = await AudioPlaybackService.extractChapters(from: output)
        XCTAssertEqual(chapters.map(\.startTime), [0, 4, 8].map(TimeInterval.init), accuracy: 0.01)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 12, accuracy: 0.02)
    }

    /// An m4b's own chapters follow a cut: one inside it moves to where it
    /// was, those after it move back, and the file keeps them as an m4b.
    func testAnM4BsChaptersAreUpdatedByTheEdits() async throws {
        let folder = try makeFolder()
        let book = folder.appendingPathComponent("Ferry Tales.m4b")
        try await AudioTestFixtures.writeChapteredAAC(to: book, duration: 30, chapters: [
            .init(title: "One", start: 0, duration: 10),
            .init(title: "Two", start: 10, duration: 10),
            .init(title: "Three", start: 20, duration: 10),
        ])
        let base = try await AudioEditBase.load(book, name: "Ferry Tales.m4b")
        XCTAssertEqual(base.chapters.map(\.title), ["One", "Two", "Three"])
        var timeline = base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 5, end: 15)))
        let output = folder.appendingPathComponent("edited.m4b")

        _ = try await AudioEditRenderer.render(
            timeline,
            sources: AudioEditComposition.Sources(base: base, package: folder, scratch: folder),
            to: output,
            format: .aacM4B,
            metadata: AudioRenderMetadata(title: "Ferry Tales", author: nil)
        )

        let chapters = await AudioPlaybackService.extractChapters(from: output)
        XCTAssertEqual(chapters.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 5, 10], accuracy: 0.01)
        XCTAssertEqual(chapters.map(\.duration), [5, 5, 10], accuracy: 0.05)
        let parsed = try await AudioBookParser.parse(url: output)
        XCTAssertEqual(parsed.chapters.map(\.title), ["One", "Two", "Three"])
    }

    /// A ten-minute file gets its chapters too: the chapter titles are laid
    /// out ahead of the audio, without which the writer refuses a title the
    /// audio hasn't reached and stalls (the research prototype).
    func testALongFileGetsItsChapters() async throws {
        let folder = try makeFolder()
        let base = folder.appendingPathComponent("long.caf")
        try AudioTestFixtures.writeTones([.init(seconds: 600, frequency: 220, amplitude: 0.2)], to: base, sampleRate: Self.rate)
        let loaded = try await AudioEditBase.load(base, name: "long.caf")
        var timeline = loaded.timeline
        try timeline.applyRearranging(.setChapter(at: 0, title: "Morning"))
        try timeline.applyRearranging(.setChapter(at: 200, title: "Noon"))
        try timeline.applyRearranging(.setChapter(at: 400, title: "Evening"))
        let output = folder.appendingPathComponent("Long Day.m4a")

        _ = try await AudioEditRenderer.render(
            timeline,
            sources: AudioEditComposition.Sources(base: loaded, package: folder, scratch: folder),
            to: output,
            format: .aacM4A,
            metadata: AudioRenderMetadata(title: "Long Day", author: nil)
        )

        let chapters = await AudioPlaybackService.extractChapters(from: output)
        XCTAssertEqual(chapters.map(\.title), ["Morning", "Noon", "Evening"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 200, 400], accuracy: 0.01)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 600, accuracy: 0.02)
    }

    // MARK: - Samples Kept As Stored

    /// An edit of chapter markers alone keeps an m4b's AAC samples as they
    /// were, encoding nothing again, and writes the new markers.
    func testAChapterOnlyEditKeepsTheAACSamples() async throws {
        let folder = try makeFolder()
        let book = folder.appendingPathComponent("Ferry Tales.m4b")
        try await AudioTestFixtures.writeChapteredAAC(to: book, duration: 6, chapters: [
            .init(title: "One", start: 0, duration: 3),
            .init(title: "Two", start: 3, duration: 3),
        ])
        let base = try await AudioEditBase.load(book, name: "Ferry Tales.m4b")
        var timeline = base.timeline
        try timeline.applyRearranging(.setChapter(at: 4.5, title: "Two and a Half"))
        let output = folder.appendingPathComponent("edited.m4b")

        let outcome = try await AudioEditRenderer.render(
            timeline,
            sources: AudioEditComposition.Sources(base: base, package: folder, scratch: folder),
            to: output,
            format: .aacM4B,
            metadata: AudioRenderMetadata(title: "Ferry Tales", author: nil)
        )

        XCTAssertTrue(outcome.copiedSamples)
        let chapters = await AudioPlaybackService.extractChapters(from: output)
        XCTAssertEqual(chapters.map(\.title), ["One", "Two", "Two and a Half"])
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.05)
    }

    /// Cuts of 16-bit PCM are copied as stored into a WAVE file, every
    /// sample the same.
    func testCutsOfPCMAreCopiedAsStored() async throws {
        let folder = try makeFolder()
        let book = folder.appendingPathComponent("Ferry Tales.wav")
        try AudioTestFixtures.writeInt16Pattern(to: book, frames: 24_000, sampleRate: Self.rate)
        let base = try await AudioEditBase.load(book, name: "Ferry Tales.wav")
        var timeline = base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
        let output = folder.appendingPathComponent("edited.wav")

        let outcome = try await AudioEditRenderer.render(
            timeline,
            sources: AudioEditComposition.Sources(base: base, package: folder, scratch: folder),
            to: output,
            format: .pcmWAV,
            metadata: AudioRenderMetadata(title: "Ferry Tales", author: nil)
        )

        XCTAssertTrue(outcome.copiedSamples)
        let original = try AudioTestFixtures.int16Samples(of: book)
        XCTAssertEqual(try AudioTestFixtures.int16Samples(of: output), Array(original.prefix(8_000) + original.suffix(8_000)))
    }

    // MARK: - A Punch-In Through a Session

    /// A punch-in made through a session keeps its take in the package,
    /// compressed losslessly, and the preview plays the take's samples
    /// exactly where the replaced range was.
    @MainActor
    func testAPunchInPlaysItsTakeExactly() async throws {
        let (model, book) = try makeLibraryBook(seconds: 4)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        let folder = try makeFolder()
        let take = folder.appendingPathComponent("take.caf")
        try AudioTestFixtures.writeInt16Pattern(to: take, frames: 12_000, sampleRate: Self.rate)

        let entry = try await session.punchIn(
            replacing: AudioTimeRange(start: 1, end: 2),
            withTakeAt: take,
            using: AudioTimeRange(start: 0.25, end: 1.25)
        )

        let kept = try XCTUnwrap(entry.edit.take)
        XCTAssertTrue(kept.file.hasPrefix("audioEdits/takes/"), kept.file)
        let keptFile = book.tmbDirectory.appendingPathComponent(kept.file)
        let format = AudioEditPackage.streamDescription(of: try AVAudioFile(forReading: keptFile).fileFormat)
        XCTAssertEqual(format.mFormatID, kAudioFormatAppleLossless)
        XCTAssertEqual(session.duration, 4)

        let samples = try await Self.compositionSamples(try await session.makePreview())
        XCTAssertEqual(samples.count, 32_000)
        let replaced = Array(samples[min(8_000, samples.count)..<min(16_000, samples.count)])
        let takeSamples = try AudioTestFixtures.int16Samples(of: take)
        let expected = takeSamples.dropFirst(2_000).prefix(8_000).map { Float($0) / 32_768 }
        XCTAssertEqual(replaced, Array(expected))
        XCTAssertEqual(samples[checked: 7_999].map(AudioTestFixtures.rampSample), .frame(.book, 7_999))
        XCTAssertEqual(samples[checked: 16_000].map(AudioTestFixtures.rampSample), .frame(.book, 16_000))
    }

    // MARK: - Helpers

    /// A timeline of the exactness tests' edits over 30 seconds of book
    /// ramp, with a 2-second take ramp kept in the package, and its sources;
    /// and the folder serving as package and scratch folder.
    private func makeEditedTimeline() async throws -> (AudioEditTimeline, AudioEditComposition.Sources, URL) {
        let (sources, folder) = try await makeRampSources(seconds: 30)
        try AudioTestFixtures.writeIdentityRamp(
            to: folder.appendingPathComponent("audioEdits/takes/take.caf"),
            frames: 16_000,
            sampleRate: Self.rate,
            source: .take
        )
        var timeline = sources.base.timeline
        for edit in Self.edits {
            try timeline.applyRearranging(edit)
        }
        return (timeline, sources, folder)
    }

    /// The sources of an edit whose base is `seconds` of book ramp, in a
    /// folder of this test's own serving as package and scratch folder.
    private func makeRampSources(seconds: Double) async throws -> (AudioEditComposition.Sources, URL) {
        let folder = try makeFolder()
        let base = folder.appendingPathComponent("Canal Survey.caf")
        try AudioTestFixtures.writeIdentityRamp(to: base, frames: Int(seconds * Self.rate), sampleRate: Self.rate)
        let loaded = try await AudioEditBase.load(base, name: "Canal Survey.caf")
        return (AudioEditComposition.Sources(base: loaded, package: folder, scratch: folder), folder)
    }

    /// Checks that `samples` are exactly `expectedPieces`, naming the first
    /// samples that aren't.
    private func assertMatchesExpectedPieces(_ samples: [Float], _ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        var expected: [AudioTestFixtures.RampSample] = []
        for piece in Self.expectedPieces {
            for offset in 0..<piece.length {
                expected.append(piece.source.map { .frame($0, piece.start + offset) } ?? .silence)
            }
        }
        XCTAssertEqual(samples.count, expected.count, "\(label) length", file: file, line: line)
        let found = samples.map(AudioTestFixtures.rampSample)
        let wrong = zip(found, expected).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(wrong.count, 0, "\(label): first wrong samples \(wrong.prefix(3).map { "at \($0.offset): \($0.element.0) for \($0.element.1)" })", file: file, line: line)
    }

    /// Every sample of `made`'s composition, read as AVAssetReader reads it,
    /// as mono 32-bit floats at the timeline's rate.
    private static func compositionSamples(_ made: AudioEditComposition) async throws -> [Float] {
        let tracks = try await made.composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: made.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: made.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let address = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: address)
            }
            XCTAssertEqual(status, noErr)
            samples.append(contentsOf: chunk)
        }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }

    /// A library of one WAVE audiobook of `seconds` of book ramp, in a
    /// folder of the sandbox's library of this test's own.
    @MainActor
    private func makeLibraryBook(seconds: Double) throws -> (LibraryViewModel, Book) {
        let folderPath = "Audio Rendering \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let package = folder.appendingPathComponent("Canal-Unknown-1-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        model.audioFilterEngine = { .builtIn }
        let book = Book(
            title: "Canal Survey",
            format: .audio,
            filePath: package.appendingPathComponent("Canal Survey.wav").path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            AudioEditScratch.remove(for: book.id)
        }
        try AudioTestFixtures.writeIdentityRamp(to: book.bookFileURL, frames: Int(seconds * Self.rate), sampleRate: Self.rate)
        model.library.addBook(book)
        return (model, book)
    }

    /// A new folder of this test's own, removed when it ends.
    private func makeFolder() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

/// Progress reported by a render, handed from its task to the test.
private final class ProgressReports: Sendable {
    /// The values, behind a lock.
    private let stored = OSAllocatedUnfairLock<[Double]>(initialState: [])

    /// Every value reported, in order.
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
