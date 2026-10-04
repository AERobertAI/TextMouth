import AVFoundation
import XCTest
@testable import TextMouth

/// Exporting edited audio (FR04): the formats Export offers, MP3 among them
/// only with an installed ffmpeg TextMouth may use; MP3 encoded through
/// ffmpeg with LAME, tagged, its chapter markers as ID3 chapter frames, as
/// a stub ffmpeg on PATH records; an MP3 book kept MP3 when saved only with
/// ffmpeg; and a session exporting its edits, sample-exact. Two tests run a
/// real ffmpeg when this Mac has one and are skipped otherwise.
final class AudioExportTests: XCTestCase {

    /// Frames a second of the audio.
    private static let rate = 8_000.0

    // MARK: - The Formats Offered

    /// Export offers every format TextMouth writes itself, and MP3 only when
    /// an installed ffmpeg may be used, under the name the user asked for.
    func testMP3IsOfferedOnlyWithFFmpeg() {
        XCTAssertEqual(AudioExportFormat.available(ffmpeg: nil), [.m4a, .m4b, .appleLossless, .wav, .aiff, .caf])
        let ffmpeg = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(AudioExportFormat.available(ffmpeg: ffmpeg).last, .mp3)
        XCTAssertEqual(AudioExportFormat.mp3.title, "MP3 (needs ffmpeg)")
        XCTAssertEqual(AudioExportFormat.allCases.map(\.fileExtension), ["m4a", "m4b", "m4a", "wav", "aiff", "caf", "mp3"])
    }

    /// An MP3 book is saved as MP3 when ffmpeg may write it, and as AAC in
    /// an .m4a file otherwise; other formats keep their own.
    func testAnMP3BookStaysMP3OnlyWithFFmpeg() {
        var mp3 = AudioStreamBasicDescription()
        mp3.mFormatID = kAudioFormatMPEGLayer3
        let ffmpeg = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(AudioRenderFormat.inPlace(forFileNamed: "Weir.mp3", stored: mp3, ffmpeg: ffmpeg), .mp3)
        XCTAssertEqual(AudioRenderFormat.inPlace(forFileNamed: "Weir.mp3", stored: mp3, ffmpeg: nil), .aacM4A)
        XCTAssertEqual(AudioRenderFormat.mp3.fileName(replacing: "Weir.mp3"), "Weir.mp3")
        XCTAssertEqual(AudioRenderFormat.aacM4A.fileName(replacing: "Weir.mp3"), "Weir.m4a")
        XCTAssertEqual(AudioRenderFormat.pcmAIFF.fileName(replacing: "Weir.aif"), "Weir.aif")
    }

    // MARK: - MP3 Through ffmpeg

    /// MP3 is rendered to PCM, then encoded by ffmpeg with LAME at 64 kbit/s
    /// a channel, tagged with the title and author, with every chapter
    /// marker as an ID3 chapter frame from a metadata file.
    func testMP3IsEncodedThroughFFmpegWithTagsAndChapters() async throws {
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

        _ = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: output,
            format: .mp3,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: "Ferry Office"),
            ffmpeg: FFmpeg(executable: ffmpeg)
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

    /// MP3 without ffmpeg is refused with a sentence saying what it needs.
    func testMP3WithoutFFmpegIsRefused() async throws {
        let (sources, folder) = try await makeSources(seconds: 1)
        do {
            _ = try await AudioEditRenderer.render(
                sources.base.timeline,
                sources: sources,
                to: folder.appendingPathComponent("out.mp3"),
                format: .mp3,
                metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
            )
            XCTFail("MP3 was written without ffmpeg")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .mp3NeedsFFmpeg)
            XCTAssertEqual(error.localizedDescription, "MP3 needs ffmpeg, which isn't installed, or is turned off in Storage settings.")
        }
    }

    /// With ffmpeg installed on this Mac, MP3 really is written: a file that
    /// plays and lasts as long as the edits, LAME's delay and padding aside,
    /// which AVFoundation counts (`FFmpeg.mp3Excess`). Skipped on a Mac
    /// without ffmpeg.
    func testAnInstalledFFmpegWritesAnMP3ThatPlays() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed on this Mac") }
        let (sources, folder) = try await makeSources(seconds: 2)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 0.5, end: 1)))
        let output = folder.appendingPathComponent("Canal Survey.mp3")

        _ = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: output,
            format: .mp3,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: nil),
            ffmpeg: ffmpeg
        )

        let asset = AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 1.5 - AudioEditBookRender.lengthTolerance)
        XCTAssertLessThanOrEqual(duration, 1.5 + FFmpeg.mp3Excess(sampleRate: Self.rate) + AudioEditBookRender.lengthTolerance)
    }

    /// An MP3 book's edits are saved into its file as MP3 through an
    /// installed ffmpeg: the file keeps its name and its format, and lasts as
    /// long as the edits, LAME's delay and padding aside. Skipped on a Mac
    /// without ffmpeg.
    @MainActor
    func testAnMP3BookIsSavedAsMP3ThroughAnInstalledFFmpeg() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed on this Mac") }
        let (model, book) = try makeLibrary(withBookNamed: "Canal Survey.mp3")
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let tone = folder.appendingPathComponent("tone.caf")
        try AudioTestFixtures.writeTones([.init(seconds: 3, frequency: 440, amplitude: 0.3)], to: tone, sampleRate: Self.rate)
        try await ffmpeg.encodeMP3(
            tone,
            to: book.bookFileURL,
            bitRate: 32_000,
            sampleRate: Self.rate,
            channels: 1,
            metadata: AudioRenderMetadata(title: "Canal Survey", author: nil),
            chapters: [],
            scratch: folder
        )
        model.audioFilterEngine = { .ffmpeg(ffmpeg) }
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
        XCTAssertGreaterThanOrEqual(outcome.duration, edited - AudioEditBookRender.lengthTolerance)
        XCTAssertLessThanOrEqual(outcome.duration, edited + FFmpeg.mp3Excess(sampleRate: Self.rate) + AudioEditBookRender.lengthTolerance)
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

        model.audioFilterEngine = { .builtIn }
        XCTAssertFalse(session.exportFormats.contains(.mp3))
        do {
            try await session.export(to: folder.appendingPathComponent("x.mp3"), as: .mp3)
            XCTFail("MP3 was exported without ffmpeg")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .mp3NeedsFFmpeg)
        }
    }

    // MARK: - Helpers

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
