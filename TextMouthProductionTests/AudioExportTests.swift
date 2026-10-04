import AVFoundation
import os
import XCTest
@testable import TextMouth

/// Exporting edited audio (FR04): the formats Export offers, MP3 among them
/// through the LAME encoder built into TextMouth; MP3 encoded with it,
/// tagged, its chapter markers as ID3 chapter frames, read back through the
/// app's parser; should LAME be unavailable, MP3 through an installed ffmpeg,
/// as a stub ffmpeg records, and refused with neither; an MP3 book kept MP3
/// when saved; and a session exporting its edits, sample-exact. One test
/// runs a real ffmpeg when this Mac has one and is skipped otherwise.
final class AudioExportTests: XCTestCase {

    /// Frames a second of the audio.
    private static let rate = 8_000.0

    // MARK: - The Formats Offered

    /// Export offers every format Core Audio writes and MP3, written by the
    /// LAME built in, under its plain name, with no ffmpeg needed; only were
    /// LAME unavailable would MP3 wait for an installed ffmpeg.
    func testMP3IsOfferedThroughTheBuiltInEncoder() {
        let all: [AudioExportFormat] = [.m4a, .m4b, .appleLossless, .wav, .aiff, .caf, .mp3]
        XCTAssertEqual(AudioExportFormat.available(ffmpeg: nil), all)
        XCTAssertEqual(AudioExportFormat.mp3.title, "MP3")
        XCTAssertFalse(AudioExportFormat.mp3.needsFFmpeg)
        XCTAssertEqual(AudioExportFormat.available(ffmpeg: nil, builtInMP3: false), Array(all.dropLast()))
        let ffmpeg = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(AudioExportFormat.available(ffmpeg: ffmpeg, builtInMP3: false), all)
        XCTAssertEqual(AudioExportFormat.allCases.map(\.fileExtension), ["m4a", "m4b", "m4a", "wav", "aiff", "caf", "mp3"])
    }

    /// An MP3 book is saved as MP3, by the LAME built in; only with neither
    /// it nor an installed ffmpeg would it become AAC in an .m4a file. Other
    /// formats keep their own.
    func testAnMP3BookStaysMP3() {
        var mp3 = AudioStreamBasicDescription()
        mp3.mFormatID = kAudioFormatMPEGLayer3
        let ffmpeg = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(AudioRenderFormat.inPlace(forFileNamed: "Weir.mp3", stored: mp3, ffmpeg: nil), .mp3)
        XCTAssertEqual(AudioRenderFormat.inPlace(forFileNamed: "Weir.mp3", stored: mp3, ffmpeg: ffmpeg, builtInMP3: false), .mp3)
        XCTAssertEqual(AudioRenderFormat.inPlace(forFileNamed: "Weir.mp3", stored: mp3, ffmpeg: nil, builtInMP3: false), .aacM4A)
        XCTAssertEqual(AudioRenderFormat.mp3.fileName(replacing: "Weir.mp3"), "Weir.mp3")
        XCTAssertEqual(AudioRenderFormat.aacM4A.fileName(replacing: "Weir.mp3"), "Weir.m4a")
        XCTAssertEqual(AudioRenderFormat.pcmAIFF.fileName(replacing: "Weir.aif"), "Weir.aif")
    }

    // MARK: - MP3 With the Built-In LAME

    /// MP3 is encoded with the LAME built in, without ffmpeg: a file that
    /// lasts as long as the edits, at 64 kbit/s a channel, whose title,
    /// author, and chapter markers, the sound before the first marker in a
    /// chapter of the book's title, read back through the app's parser.
    func testMP3IsEncodedWithTheBuiltInLAMEWithTagsAndChapters() async throws {
        let (sources, folder) = try await makeSources(seconds: 3)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.setChapter(at: 1, title: "Locks; Weirs = Water"))
        let output = folder.appendingPathComponent("Canal Survey.mp3")
        let progress = ProgressLog()

        let outcome = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: output,
            format: .mp3,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: "Ferry Office"),
            progress: { progress.record($0) }
        )

        XCTAssertEqual(outcome, AudioEditRenderer.Outcome(frames: 24_000, copiedSamples: false))
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(
            AudioEditRenderer.mp3EncoderSettings(for: sources.base),
            MP3EncoderSettings(sampleRate: 8_000, channels: 1, kilobitsPerSecond: 64)
        )
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 24_000, "the MP3 does not last as long as the edits")
        let content = try await AudioBookParser.parse(url: output)
        XCTAssertEqual(content.title, "Canal Survey")
        XCTAssertEqual(content.author, "Ferry Office")
        XCTAssertEqual(content.chapters.map(\.title), ["Canal Survey", "Locks; Weirs = Water"])
    }

    // MARK: - MP3 Through ffmpeg, Without LAME

    /// Were LAME unavailable, MP3 would be rendered to PCM, then encoded by
    /// an installed ffmpeg with LAME at 64 kbit/s a channel, tagged with the
    /// title and author, with every chapter marker as an ID3 chapter frame
    /// from a metadata file.
    func testWithoutLAMEMP3IsEncodedThroughFFmpegWithTagsAndChapters() async throws {
        let (sources, folder) = try await makeSources(seconds: 3)
        let arguments = folder.appendingPathComponent("arguments.txt")
        let chapters = folder.appendingPathComponent("chapters.txt")
        let ffmpeg = try writeStub(in: folder.appendingPathComponent("bin"), body: """
            printf '%s\\n' "$@" > '\(arguments.path)'
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "-i" ]; then case "$argument" in *.txt) cp "$argument" '\(chapters.path)';; esac; fi
              previous="$argument"
            done
            printf 'ID3' > "$previous"
            """)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.setChapter(at: 1, title: "Locks; Weirs = Water"))
        let output = folder.appendingPathComponent("Canal Survey.mp3")

        _ = try await AudioEditRenderer.renderMP3(
            timeline,
            sources: sources,
            to: output,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: "Ferry Office"),
            route: MP3Route.preferred(ffmpeg: FFmpeg(executable: ffmpeg), builtInIsAvailable: false),
            progress: nil
        )

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "ID3")
        let passed = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        for (option, value) in [("-c:a", "libmp3lame"), ("-b:a", "64k"), ("-ar", "8000"), ("-ac", "1"), ("-map_chapters", "1")] {
            let index = try XCTUnwrap(passed.firstIndex(of: option), option)
            XCTAssertEqual(passed[checked: index + 1], value, option)
        }
        XCTAssertTrue(passed.contains("title=Canal Survey"), "\(passed)")
        XCTAssertTrue(passed.contains("artist=Ferry Office"), "\(passed)")
        XCTAssertEqual(passed.last, output.path)
        XCTAssertEqual(try String(contentsOf: chapters, encoding: .utf8), """
            ;FFMETADATA1

            [CHAPTER]
            TIMEBASE=1/1000
            START=0
            END=1000
            title=Canal Survey

            [CHAPTER]
            TIMEBASE=1/1000
            START=1000
            END=3000
            title=Locks\\; Weirs \\= Water

            """)
    }

    /// MP3 with neither LAME nor ffmpeg is refused with a sentence saying
    /// why.
    func testMP3WithNeitherEncoderIsRefused() async throws {
        let (sources, folder) = try await makeSources(seconds: 1)
        do {
            _ = try await AudioEditRenderer.renderMP3(
                sources.base.timeline,
                sources: sources,
                to: folder.appendingPathComponent("out.mp3"),
                metadata: AudioRenderMetadata(title: "Canal Survey", author: nil),
                route: MP3Route.preferred(ffmpeg: nil, builtInIsAvailable: false),
                progress: nil
            )
            XCTFail("MP3 was written with no encoder")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .mp3NeedsFFmpeg)
            XCTAssertEqual(
                error.localizedDescription,
                "MP3 can't be written: TextMouth's own encoder couldn't start, and ffmpeg isn't installed, "
                    + "or is turned off in Storage settings."
            )
        }
    }

    /// With ffmpeg installed on this Mac, its route really writes MP3: a
    /// file that plays and lasts as long as the edits, LAME's delay and
    /// padding aside, which AVFoundation counts (`FFmpeg.mp3Excess`).
    /// Skipped on a Mac without ffmpeg.
    func testAnInstalledFFmpegWritesAnMP3ThatPlays() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed on this Mac") }
        let (sources, folder) = try await makeSources(seconds: 2)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 0.5, end: 1)))
        let output = folder.appendingPathComponent("Canal Survey.mp3")

        _ = try await AudioEditRenderer.renderMP3(
            timeline,
            sources: sources,
            to: output,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: nil),
            route: .ffmpeg(ffmpeg),
            progress: nil
        )

        let asset = AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 1.5 - AudioEditBookRender.lengthTolerance)
        XCTAssertLessThanOrEqual(duration, 1.5 + FFmpeg.mp3Excess(sampleRate: Self.rate) + AudioEditBookRender.lengthTolerance)
    }

    /// An MP3 book's edits are saved into its file as MP3 by the LAME built
    /// in, with no ffmpeg: the file keeps its name and its format, and lasts
    /// as long as the edits.
    @MainActor
    func testAnMP3BookIsSavedAsMP3() async throws {
        let (model, book) = try makeLibrary(withBookNamed: "Canal Survey.mp3")
        let tone = (0..<24_000).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / Self.rate)) }
        let encoder = try MP3Encoder(
            writingTo: book.bookFileURL,
            settings: MP3EncoderSettings(sampleRate: Int(Self.rate), channels: 1, kilobitsPerSecond: 32),
            tag: MP3Tag(title: "Canal Survey")
        )
        try tone.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
        try encoder.finish()
        model.audioFilterEngine = { .builtIn }
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        let edited = session.duration - 1
        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))

        let outcome = try await session.save()

        XCTAssertEqual(outcome.audioFile, "Canal Survey.mp3", "the book's file kept its name")
        let tracks = try await AVURLAsset(url: book.tmbDirectory.appendingPathComponent(outcome.audioFile))
            .loadTracks(withMediaType: .audio)
        let format = try await tracks.first?.load(.formatDescriptions).first?.audioStreamBasicDescription
        XCTAssertEqual(format?.mFormatID, kAudioFormatMPEGLayer3)
        XCTAssertEqual(outcome.duration, edited, accuracy: AudioEditBookRender.lengthTolerance)
    }

    // MARK: - A Session's Export

    /// A session exports its edits as they stand, unsaved, to a file of the
    /// format asked for, sample-exact for PCM, leaving the book's file alone.
    @MainActor
    func testASessionExportsItsEdits() async throws {
        let (model, book) = try makeLibraryBook(frames: 24_000)
        let before = try Data(contentsOf: book.bookFileURL)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let exported = folder.appendingPathComponent("Canal Survey.wav")

        try await session.export(to: exported, as: .wav)

        let samples = try AudioTestFixtures.floatSamples(of: exported)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples[checked: 7_999].map(AudioTestFixtures.rampSample), .frame(.book, 7_999))
        XCTAssertEqual(samples[checked: 8_000].map(AudioTestFixtures.rampSample), .frame(.book, 16_000))
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), before, "the book's file changed")
        XCTAssertTrue(session.hasUnsavedEdits)

        // MP3 needs no ffmpeg: the LAME built in writes it.
        model.audioFilterEngine = { .builtIn }
        XCTAssertTrue(session.exportFormats.contains(.mp3))
        let mp3 = folder.appendingPathComponent("Canal Survey.mp3")
        try await session.export(to: mp3, as: .mp3)
        XCTAssertEqual(try AVAudioFile(forReading: mp3).length, 16_000, "the MP3 does not last as long as the edits")
    }

    // MARK: - Helpers

    /// The progress a render reported, in order, from whatever thread it
    /// reports on.
    private final class ProgressLog: Sendable {
        /// The values reported, behind a lock.
        private let values = OSAllocatedUnfairLock<[Double]>(initialState: [])

        /// Notes `value`.
        func record(_ value: Double) {
            values.withLock { $0.append(value) }
        }

        /// The last value reported, if any.
        var last: Double? {
            values.withLock { $0.last }
        }
    }

    /// The sources of an edit whose base is an identity ramp lasting
    /// `seconds`, in a folder of this test's own serving as package and
    /// scratch folder.
    private func makeSources(seconds: Double) async throws -> (AudioEditComposition.Sources, URL) {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("Canal Survey.caf")
        try AudioTestFixtures.writeIdentityRamp(to: base, frames: Int(seconds * Self.rate), sampleRate: Self.rate)
        let loaded = try await AudioEditBase.load(base, name: "Canal Survey.caf")
        return (AudioEditComposition.Sources(base: loaded, package: folder, scratch: folder), folder)
    }

    /// A library of one WAVE audiobook of `frames` frames of identity ramp,
    /// in a folder of the sandbox's library of this test's own.
    @MainActor
    private func makeLibraryBook(frames: Int) throws -> (LibraryViewModel, Book) {
        let (model, book) = try makeLibrary(withBookNamed: "Canal Survey.wav")
        try AudioTestFixtures.writeIdentityRamp(to: book.bookFileURL, frames: frames, sampleRate: Self.rate)
        return (model, book)
    }

    /// A library of one audiobook whose file is named `fileName`, in a
    /// folder of the sandbox's library of this test's own; the caller writes
    /// the file, at `book.bookFileURL`.
    @MainActor
    private func makeLibrary(withBookNamed fileName: String) throws -> (LibraryViewModel, Book) {
        let folderPath = "Audio Export \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let package = folder.appendingPathComponent("Canal-Unknown-1-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let book = Book(
            title: "Canal Survey",
            format: .audio,
            filePath: package.appendingPathComponent(fileName).path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            AudioEditScratch.remove(for: book.id)
        }
        model.library.addBook(book)
        return (model, book)
    }

    /// An executable shell script named ffmpeg in `folder`, running `body`.
    private func writeStub(in folder: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = folder.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }
}
