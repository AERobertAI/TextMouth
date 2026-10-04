import AVFoundation
import XCTest
@testable import TextMouth

/// Writing MP3 with the LAME encoder built into TextMouth (FR04): LAME is
/// there and is 3.100; the settings for speech, and the ones no MP3 can
/// have; the ID3 tag, byte by byte; an MP3 playing through AVFoundation as
/// long as its sound; the iTunes gapless comment, which AVFoundation
/// honours, shown by an MP3 written with and without it; and an MP3 read
/// back through the app's own parser with its title, author, and chapters.
///
/// Every MP3 is written to a folder of the test's own and decoded, never
/// played aloud.
final class MP3EncoderTests: XCTestCase {

    // MARK: - LAME

    /// LAME is linked into the app, so writing MP3 needs no ffmpeg: it
    /// starts, it is the version vendored, and MP3 takes its route.
    func testLAMEIsBuiltIn() {
        XCTAssertTrue(MP3Encoder.isAvailable)
        XCTAssertEqual(MP3Encoder.version, "3.100")
        XCTAssertEqual(MP3Route.preferred(ffmpeg: nil), .builtIn)
        let ffmpeg = FFmpeg(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(MP3Route.preferred(ffmpeg: ffmpeg), .builtIn, "an installed ffmpeg took the place of LAME")
        XCTAssertEqual(MP3Route.preferred(ffmpeg: ffmpeg, builtInIsAvailable: false), .ffmpeg(ffmpeg))
        XCTAssertNil(MP3Route.preferred(ffmpeg: nil, builtInIsAvailable: false))
    }

    // MARK: - Settings

    /// Speech is encoded at 64 kbit/s a channel; a sample rate no MP3 has,
    /// more than two channels, and no bit rate at all are each refused.
    func testSpeechSettingsAndTheOnesNoMP3CanHave() {
        XCTAssertEqual(MP3EncoderSettings.speech(sampleRate: 44_100, channels: 1).kilobitsPerSecond, 64)
        XCTAssertEqual(MP3EncoderSettings.speech(sampleRate: 22_050, channels: 2).kilobitsPerSecond, 128)
        for rate in MP3EncoderSettings.sampleRates {
            XCTAssertNil(MP3EncoderSettings.speech(sampleRate: rate, channels: 1).problem, "\(rate)")
        }
        XCTAssertNotNil(MP3EncoderSettings(sampleRate: 96_000, channels: 1, kilobitsPerSecond: 64).problem)
        XCTAssertNotNil(MP3EncoderSettings(sampleRate: 44_100, channels: 3, kilobitsPerSecond: 64).problem)
        XCTAssertNotNil(MP3EncoderSettings(sampleRate: 44_100, channels: 1, kilobitsPerSecond: 0).problem)
    }

    /// LAME takes the bit rate nearest the one asked that an MP3 at the
    /// sample rate can have: at 8 kHz at most 64 kbit/s, so stereo speech's
    /// 128 becomes 64; at 44.1 kHz it takes 128 as it is.
    func testLAMETakesTheNearestBitRateTheSampleRateAllows() throws {
        let folder = try makeFolder()
        let narrow = try MP3Encoder(
            writingTo: folder.appendingPathComponent("narrow.mp3"),
            settings: .speech(sampleRate: 8_000, channels: 2),
            tag: MP3Tag()
        )
        XCTAssertEqual(narrow.settings, MP3EncoderSettings(sampleRate: 8_000, channels: 2, kilobitsPerSecond: 64))
        try narrow.finish()
        let wide = try MP3Encoder(
            writingTo: folder.appendingPathComponent("wide.mp3"),
            settings: .speech(sampleRate: 44_100, channels: 2),
            tag: MP3Tag()
        )
        XCTAssertEqual(wide.settings.kilobitsPerSecond, 128)
        try wide.finish()
    }

    /// Settings no MP3 can have are refused before anything is written.
    func testSettingsNoMP3CanHaveLeaveNoFile() throws {
        let url = try makeFolder().appendingPathComponent("refused.mp3")
        XCTAssertThrowsError(try MP3Encoder(
            writingTo: url,
            settings: MP3EncoderSettings(sampleRate: 96_000, channels: 1, kilobitsPerSecond: 64),
            tag: MP3Tag()
        )) { error in
            guard case MP3EncoderError.unsupportedSettings = error else {
                return XCTFail("refused for another reason: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// An MP3 the encoder never finishes, as when encoding fails or is
    /// cancelled, is removed as the encoder goes; samples that are not a
    /// whole number of frames are refused.
    func testAnUnfinishedMP3IsRemoved() throws {
        let url = try makeFolder().appendingPathComponent("unfinished.mp3")
        do {
            let encoder = try MP3Encoder(writingTo: url, settings: .speech(sampleRate: 8_000, channels: 2), tag: MP3Tag())
            try withExtendedLifetime(encoder) {
                let samples = Self.tone(frames: 4_000, sampleRate: 8_000, channels: 2)
                try samples.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
                XCTAssertThrowsError(try [Float](repeating: 0, count: 3).withUnsafeBufferPointer {
                    try encoder.encode(interleaved: $0)
                })
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an unfinished MP3 was left behind")
    }

    // MARK: - The Tag

    /// The tag is ID3 version 2.3: its header with the size of what follows
    /// as a synchsafe number, then the title and author in UTF-16, the
    /// table of contents listing the chapters in order, each chapter with
    /// its times in milliseconds and its title, and the gapless comment.
    func testTheTagIsID3Version2Point3() throws {
        let chapters = [
            AudioRenderChapter(start: 0, duration: 1.5, title: "Locks"),
            AudioRenderChapter(start: 1.5, duration: 2.25, title: "Weirs — Café"),
        ]
        let gapless = MP3GaplessInfo(priming: 576, padding: 672, sampleCount: 12_000)
        let tag = MP3Tag(title: "Canal Survey", artist: "Ferry Office", chapters: chapters, gapless: gapless)
        let bytes = [UInt8](tag.encoded())

        XCTAssertEqual(Array(bytes.prefix(6)), [0x49, 0x44, 0x33, 3, 0, 0], "not an ID3 2.3 header")
        let size = bytes.count >= 10
            ? (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
            : -1
        XCTAssertEqual(size, bytes.count - 10)
        XCTAssertEqual(Array(MP3Tag.synchsafe(300)), [0, 0, 2, 44], "300 is 2 × 128 + 44")

        let frames = Self.frames(in: bytes, from: 10)
        XCTAssertEqual(frames.map(\.id), ["TIT2", "TPE1", "CTOC", "CHAP", "CHAP", "COMM"])
        XCTAssertEqual(frames[checked: 0]?.content, Self.utf16Text("Canal Survey"))
        XCTAssertEqual(frames[checked: 1]?.content, Self.utf16Text("Ferry Office"))
        // "toc", top-level and ordered (0x03), listing 2 entries, ch0 and ch1.
        var table: [UInt8] = Self.terminated("toc")
        table += [0x03, 2]
        table += Self.terminated("ch0") + Self.terminated("ch1")
        XCTAssertEqual(frames[checked: 2]?.content, table, "the table is not top-level and ordered, listing ch0 and ch1")
        // "ch1", from 1,500 ms (0x05DC) to 3,750 ms (0x0EA6), byte offsets unused.
        var chapter: [UInt8] = Self.terminated("ch1")
        chapter += [0, 0, 0x05, 0xDC]
        chapter += [0, 0, 0x0E, 0xA6]
        chapter += [UInt8](repeating: 0xFF, count: 8)
        let second = try XCTUnwrap(frames[checked: 4]?.content)
        XCTAssertEqual(Array(second.prefix(20)), chapter, "the second chapter does not run from 1,500 to 3,750 milliseconds")
        XCTAssertEqual(Self.frames(in: Array(second.dropFirst(20)), from: 0).map(\.content), [Self.utf16Text("Weirs — Café")])
        let comment = try XCTUnwrap(frames[checked: 5]?.content)
        let commentStart: [UInt8] = [0] + Array("eng".utf8) + Self.terminated("iTunSMPB")
        XCTAssertEqual(Array(comment.prefix(13)), commentStart)
        XCTAssertEqual(String(decoding: comment.dropFirst(13), as: UTF8.self), gapless.commentText)
    }

    /// The gapless comment is iTunes's twelve hexadecimal fields, always 116
    /// characters, so the tag written before the numbers are known is the
    /// size of the one written after.
    func testTheGaplessCommentKeepsItsWidth() {
        let info = MP3GaplessInfo(priming: 576, padding: 672, sampleCount: 12_000)
        XCTAssertEqual(
            info.commentText,
            " 00000000 00000240 000002A0 0000000000002EE0" + String(repeating: " 00000000", count: 8)
        )
        XCTAssertEqual(info.commentText.count, 116)
        XCTAssertEqual(MP3GaplessInfo.unknown.commentText.count, 116)
        XCTAssertEqual(
            MP3Tag(title: "Weir", gapless: .unknown).encoded().count,
            MP3Tag(title: "Weir", gapless: info).encoded().count
        )
        XCTAssertEqual(MP3Tag().encoded(), Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0]), "an empty tag holds no frame")
    }

    /// An MP3 holds as many chapters as one table of contents lists, 255,
    /// the most AVFoundation reads; past that the 255th runs on to where the
    /// last ends, keeping its title, so every moment stays in a chapter.
    func testMoreChaptersThanATableListsRunTheLastToTheEnd() throws {
        let chapters = (0..<300).map { AudioRenderChapter(start: Double($0), duration: 1, title: "Part \($0 + 1)") }
        let written = MP3Tag(chapters: chapters).writtenChapters

        XCTAssertEqual(written.count, MP3Tag.maximumChapters)
        XCTAssertEqual(Array(written.prefix(254)), Array(chapters.prefix(254)))
        XCTAssertEqual(written.last, AudioRenderChapter(start: 254, duration: 46, title: "Part 255"))
        let table = Self.frames(in: [UInt8](MP3Tag(chapters: chapters).encoded()), from: 10).first { $0.id == "CTOC" }
        XCTAssertEqual(table?.content[checked: 5], 255, "the table does not list 255 chapters")
        XCTAssertEqual(MP3Tag(chapters: Array(chapters.prefix(3))).writtenChapters, Array(chapters.prefix(3)))
    }

    // MARK: - Through AVFoundation

    /// An MP3 the encoder writes plays through AVFoundation, as MP3 at its
    /// rate and channels, and lasts as long as its sound, within LAME's
    /// delay allowance (`FFmpeg.mp3Excess`); its first channel decodes to
    /// as many frames, the tone starting where it started.
    func testAnEncodedMP3PlaysThroughAVFoundationAsLongAsItsSound() async throws {
        let folder = try makeFolder()
        for (rate, channels, seconds) in [(8_000, 1, 1.5), (44_100, 2, 1.0), (22_050, 1, 2.0)] {
            let url = folder.appendingPathComponent("tone-\(rate)-\(channels).mp3")
            let frames = Int((Double(rate) * seconds).rounded())
            let samples = Self.tone(frames: frames, sampleRate: rate, channels: channels)
            let gapless = try Self.writeMP3(samples, to: url, settings: .speech(sampleRate: rate, channels: channels))
            XCTAssertEqual(gapless.sampleCount, Int64(frames))

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let (duration, isPlayable) = try await asset.load(.duration, .isPlayable)
            XCTAssertTrue(isPlayable, "\(rate) Hz does not play")
            XCTAssertGreaterThanOrEqual(duration.seconds, seconds - AudioEditBookRender.lengthTolerance, "\(rate) Hz")
            XCTAssertLessThanOrEqual(
                duration.seconds,
                seconds + FFmpeg.mp3Excess(sampleRate: Double(rate)) + AudioEditBookRender.lengthTolerance,
                "\(rate) Hz"
            )
            let track = try await asset.loadTracks(withMediaType: .audio).first
            let format = try await track?.load(.formatDescriptions).first?.audioStreamBasicDescription
            XCTAssertEqual(format?.mFormatID, kAudioFormatMPEGLayer3)
            XCTAssertEqual(format?.mChannelsPerFrame, UInt32(channels))
            XCTAssertEqual(format?.mSampleRate, Double(rate))

            let decoded = try AudioTestFixtures.floatSamples(of: url)
            XCTAssertEqual(decoded.count, frames, "\(rate) Hz decodes to another length")
            let sourceStart = Self.firstLoud(Self.leftChannel(of: samples, channels: channels))
            XCTAssertEqual(Double(Self.firstLoud(decoded)), Double(sourceStart), accuracy: 2, "\(rate) Hz starts elsewhere")
        }
    }

    /// AVFoundation honours the iTunes gapless comment, so the encoder writes
    /// it. At 22.05 kHz and 32 kbit/s, where LAME's own tag has no room in a
    /// frame, an MP3 with the comment measures and decodes exactly as long as
    /// its sound, its tone starting on the same sample; the same MP3 without
    /// it lasts longer by LAME's delay and padding, as AVFoundation counted
    /// MP3s written through ffmpeg, its tone starting LAME's delay late.
    func testAVFoundationHonoursTheGaplessComment() async throws {
        let folder = try makeFolder()
        let frames = 22_050
        let samples = Self.tone(frames: frames, sampleRate: 22_050, channels: 1)
        let settings = MP3EncoderSettings(sampleRate: 22_050, channels: 1, kilobitsPerSecond: 32)
        let with = folder.appendingPathComponent("with.mp3")
        let without = folder.appendingPathComponent("without.mp3")
        let gapless = try Self.writeMP3(samples, to: with, settings: settings)
        try Self.writeMP3(samples, to: without, settings: settings, gapless: false)
        let silence = gapless.priming + gapless.padding
        XCTAssertGreaterThan(silence, 0)

        XCTAssertEqual(try AVAudioFile(forReading: with).length, Int64(frames))
        XCTAssertEqual(try AVAudioFile(forReading: without).length, Int64(frames + silence))
        let measured = try await AVURLAsset(url: with, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            .load(.duration).seconds
        let longer = try await AVURLAsset(url: without, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            .load(.duration).seconds
        XCTAssertEqual(measured, 1, accuracy: 0.001)
        XCTAssertEqual(longer, Double(frames + silence) / 22_050, accuracy: 0.001)
        let start = Self.firstLoud(samples)
        XCTAssertEqual(Double(Self.firstLoud(try AudioTestFixtures.floatSamples(of: with))), Double(start), accuracy: 2)
        XCTAssertEqual(
            Double(Self.firstLoud(try AudioTestFixtures.floatSamples(of: without))),
            Double(start + gapless.priming),
            accuracy: 2
        )
    }

    /// Where its frame has room, LAME's own tag fills the empty frame LAME
    /// left at the start of the audio, right after the ID3 tag: an "Info"
    /// frame, as LAME names it in a constant-rate MP3, naming LAME 3.100.
    func testLAMEsOwnTagFollowsTheID3Tag() throws {
        let url = try makeFolder().appendingPathComponent("tagged.mp3")
        let tag = MP3Tag(title: "Weir")
        try Self.writeMP3(Self.tone(frames: 44_100, sampleRate: 44_100, channels: 1), to: url, settings: .speech(sampleRate: 44_100, channels: 1), tag: tag)

        let bytes = [UInt8](try Data(contentsOf: url))
        let audioStart = MP3Tag(title: "Weir", gapless: .unknown).encoded().count
        let firstFrame = Array(bytes.dropFirst(audioStart).prefix(208))
        XCTAssertEqual(firstFrame[checked: 0], 0xFF, "no MP3 frame follows the ID3 tag")
        XCTAssertNotNil(Self.range(of: Array("Info".utf8), in: firstFrame), "LAME's tag is not in the first frame")
        XCTAssertNotNil(Self.range(of: Array("LAME3.100".utf8), in: firstFrame), "LAME's tag does not name LAME 3.100")
    }

    // MARK: - Through the App's Parser

    /// An MP3 the encoder writes reads back through TextMouth's own parser
    /// as the book it was made from: its title, its author, its chapters,
    /// titles in any script, each starting where it was marked, and its
    /// length as the app's probe measures it; the audio editor, opening it,
    /// finds the same frames and markers.
    func testAnMP3RoundTripsThroughTheAppsParser() async throws {
        let url = try makeFolder().appendingPathComponent("Canal Survey.mp3")
        let chapters = [
            AudioRenderChapter(start: 0, duration: 1, title: "Locks"),
            AudioRenderChapter(start: 1, duration: 1, title: "Weirs — Café"),
            AudioRenderChapter(start: 2, duration: 1, title: "Tide ☕️"),
        ]
        let tag = MP3Tag(title: "Canal Survey", artist: "Ferry Office", chapters: chapters)
        try Self.writeMP3(Self.tone(frames: 48_000, sampleRate: 16_000, channels: 1), to: url, settings: .speech(sampleRate: 16_000, channels: 1), tag: tag)

        let content = try await AudioBookParser.parse(url: url)
        XCTAssertEqual(content.title, "Canal Survey")
        XCTAssertEqual(content.author, "Ferry Office")
        XCTAssertEqual(content.chapters.map(\.title), ["Locks", "Weirs — Café", "Tide ☕️"])
        guard case .success(let measured) = await AudioMediaProbe.duration(of: url) else {
            return XCTFail("the app's probe refused the MP3")
        }
        XCTAssertEqual(measured, 3, accuracy: 0.001)
        let markers = await AudioPlaybackService.extractChapters(from: url)
        XCTAssertEqual(markers.count, 3)
        for (marker, chapter) in zip(markers, chapters) {
            XCTAssertEqual(marker.startTime, chapter.start, accuracy: 0.001, marker.title)
        }

        let base = try await AudioEditBase.load(url, name: url.lastPathComponent)
        XCTAssertEqual(base.frames, 48_000)
        XCTAssertEqual(base.channelCount, 1)
        XCTAssertEqual(base.chapters.map(\.frame), [0, 16_000, 32_000])
    }

    // MARK: - Helpers

    /// A new, empty folder for this test's files, removed when it ends.
    private func makeFolder() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Writes `samples` as an MP3 at `url` with `settings` and `tag`, with
    /// the gapless comment unless `gapless` is false, and returns the
    /// gapless numbers.
    @discardableResult
    private static func writeMP3(
        _ samples: [Float],
        to url: URL,
        settings: MP3EncoderSettings,
        tag: MP3Tag = MP3Tag(),
        gapless: Bool = true
    ) throws -> MP3GaplessInfo {
        let encoder = try MP3Encoder(writingTo: url, settings: settings, tag: tag, writesGaplessInfo: gapless)
        try samples.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
        return try encoder.finish()
    }

    /// `frames` frames of a 440 Hz tone at half of full scale at
    /// `sampleRate`, in `channels` channels, interleaved; the right channel
    /// at half the left's level, so stereo is two channels.
    private static func tone(frames: Int, sampleRate: Int, channels: Int) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(frames * channels)
        for index in 0..<frames {
            let value = 0.5 * Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)))
            samples.append(value)
            if channels == 2 {
                samples.append(value / 2)
            }
        }
        return samples
    }

    /// The first channel of `samples`, interleaved in `channels` channels.
    private static func leftChannel(of samples: [Float], channels: Int) -> [Float] {
        stride(from: 0, to: samples.count, by: channels).map { samples[$0] }
    }

    /// The index of the first sample louder than a tenth of full scale, or
    /// −100 when there is none: where a tone starts.
    private static func firstLoud(_ samples: [Float]) -> Int {
        samples.firstIndex { abs($0) > 0.1 } ?? -100
    }

    /// The frames of an ID3 2.3 tag's bytes from `start`: each one's ID and
    /// content, read only while whole frames remain, so a damaged tag fails
    /// the test rather than stopping the test host.
    private static func frames(in bytes: [UInt8], from start: Int) -> [(id: String, content: [UInt8])] {
        var frames: [(id: String, content: [UInt8])] = []
        var offset = start
        while offset + 10 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = bytes[offset + 4..<offset + 8].reduce(0) { ($0 << 8) | Int($1) }
            let contentStart = offset + 10
            guard size >= 0, contentStart + size <= bytes.count else { break }
            frames.append((id, Array(bytes[contentStart..<contentStart + size])))
            offset = contentStart + size
        }
        return frames
    }

    /// A text frame's content: encoding 1, then `text` in UTF-16,
    /// little-endian, after its byte-order mark.
    private static func utf16Text(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = [1, 0xFF, 0xFE]
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    /// `text`'s ASCII bytes and the zero ending them, as ID3 ends an
    /// element ID or a description.
    private static func terminated(_ text: String) -> [UInt8] {
        Array(text.utf8) + [0]
    }

    /// Where `needle` first appears in `haystack`, if it does.
    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start..<start + needle.count
        }
        return nil
    }
}
