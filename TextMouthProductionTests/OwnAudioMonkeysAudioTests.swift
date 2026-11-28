import XCTest
@testable import TextMouth

/// TextMouth's own Monkey's Audio reader (`MonkeysAudioDecoder` and the
/// Monkey's Audio files beside it): every sample, from Monkey's Audio's own
/// encoder at each of its five levels, decodes to its source's samples bit
/// for bit; a file older than version 3.99 is refused in words that say
/// so; and a file that is cut, damaged, or crafted ends in an
/// `OwnAudioError`, never in a trap. Nothing is played, and no Apple audio
/// API sees a Monkey's Audio file.
final class OwnAudioMonkeysAudioTests: XCTestCase {
    // MARK: - Helpers

    /// The error decoding `bytes` to its end gives; nil when it decodes whole.
    private func failure(decoding bytes: [UInt8], verifiesChecksums: Bool = true) -> OwnAudioError? {
        do {
            var decoder: any OwnAudioDecoder = try MonkeysAudioDecoder(OwnAudioBytes(bytes), verifiesChecksums: verifiesChecksums)
            _ = try allSamples(of: &decoder)
            return nil
        } catch {
            return error as? OwnAudioError
        }
    }

    /// `bytes`, a Monkey's Audio file without a leading tag, with the
    /// two-byte field at `offset` of its header set to `value`. The header
    /// follows the descriptor, whose length is at byte 8;
    /// `ownAudioSampleBytes` promises the bytes this reads.
    private func settingHeaderField(at offset: Int, to value: UInt16, in bytes: [UInt8]) throws -> [UInt8] {
        let header = Int(try XCTUnwrap(OwnAudioLittleEndian.uint32(bytes, 8)))
        var copy = bytes
        guard header + offset + 2 <= copy.count else { throw TestError.assertionFailed("The header lies outside the file") }
        copy.replaceSubrange(header + offset..<header + offset + 2, with: [UInt8(value & 0xFF), UInt8(value >> 8)])
        return copy
    }

    // MARK: - Exact Decoding

    /// Every Monkey's Audio sample gives its source's samples back exactly:
    /// all five levels, 8 to 32 bits, floats, one to eight channels, a
    /// frame coded as one channel, silent frames, and files of several
    /// frames that start at each place in a 32-bit word.
    func testEverySampleDecodesToItsSourcesSamples() throws {
        try assertEverySampleDecodesExactly(in: "ape", as: .monkeysAudio)
    }

    /// Decoding without verifying the frames' CRCs gives the same samples.
    func testDecodingWithoutTheChecksumsGivesTheSameSamples() throws {
        let bytes = try ownAudioSampleBytes("ape/stereo16-normal.ape")
        var checked: any OwnAudioDecoder = try MonkeysAudioDecoder(OwnAudioBytes(bytes))
        var unchecked: any OwnAudioDecoder = try MonkeysAudioDecoder(OwnAudioBytes(bytes), verifiesChecksums: false)
        XCTAssertEqual(try allSamples(of: &checked), try allSamples(of: &unchecked))
    }

    /// A file of floats starts with its own signature, says so, and gives
    /// floats inside full scale; no file names a channel layout.
    func testAFloatFileGivesFloats() throws {
        let bytes = OwnAudioBytes(try ownAudioSampleBytes("ape/float32-fast.ape"))
        XCTAssertEqual(OwnAudioFormat.of(bytes), .monkeysAudio)
        XCTAssertEqual(try bytes.read(at: 0, count: 4), Array(MonkeysAudioDecoder.floatSignature.utf8))
        var floats: any OwnAudioDecoder = try MonkeysAudioDecoder(bytes)
        XCTAssertTrue(floats.stream.isFloat)
        XCTAssertNil(floats.stream.channelMask)
        let values = try allSamples(of: &floats).map { Float(bitPattern: UInt32(bitPattern: $0)) }
        XCTAssertTrue(values.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(values.map(abs).max() ?? 0, 0.05)
    }

    /// The float transform is its own undoing for every pattern tried.
    func testTheFloatTransform() {
        // The transform turns four bits of the exponent over, so zero is stored as 0x3C000000.
        XCTAssertEqual(MonkeysAudioDecoder.floatPattern(of: 0x3C00_0000), Int32(bitPattern: Float(0).bitPattern))
        for value in [Float(0.5), -0.5, 1, -1, 0.001, -123.25, .infinity] {
            let pattern = Int32(bitPattern: value.bitPattern)
            let stored = MonkeysAudioDecoder.floatPattern(of: pattern)
            XCTAssertEqual(MonkeysAudioDecoder.floatPattern(of: stored), pattern, "\(value)")
        }
    }

    /// Which channels are stored as pairs, by channel count and bit depth.
    func testWhichChannelsArePaired() {
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 1, bits: 16), [])
        for bits in [8, 16, 24, 32] {
            XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 2, bits: bits), [0], "\(bits)")
        }
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 3, bits: 16), [])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 4, bits: 24), [0, 2])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 5, bits: 16), [])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 6, bits: 16), [0, 4])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 7, bits: 24), [0, 4])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 8, bits: 16), [0, 4, 6])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 6, bits: 8), [])
        XCTAssertEqual(MonkeysAudioDecoder.pairedChannels(channels: 6, bits: 32), [])
    }

    // MARK: - Refusals

    /// A file older than version 3.99 is refused in words that say why,
    /// whatever else it holds.
    func testAnOlderFileIsRefusedWithItsReason() throws {
        var old = try ownAudioSampleBytes("ape/mono16-fast.ape")
        // Bytes 4 and 5 are the version times 1,000: 3,980 here.
        old.replaceSubrange(4..<6, with: [0x8C, 0x0F])
        XCTAssertEqual(failure(decoding: old), .unsupported(reason: OwnAudioWording.monkeysAudioOld))
        XCTAssertEqual(
            failure(decoding: Array("MAC ".utf8) + [0x5A, 0x0F] + [UInt8](repeating: 0, count: 26)),
            .unsupported(reason: OwnAudioWording.monkeysAudioOld), "Version 3.93, with its older header")
        XCTAssertEqual(
            OwnAudioWording.sentence(for: .unsupported(reason: OwnAudioWording.monkeysAudioOld), fileName: "Disc.ape"),
            "TextMouth can't read the audio file Disc.ape because it was made by a Monkey's Audio older than "
                + "version 3.99, from before 2004."
        )
    }

    /// A compression level, a channel count, or a bit depth the format
    /// does not have is refused as a shape TextMouth does not read.
    func testAShapeOutsideTheFormatIsRefused() throws {
        let bytes = try ownAudioSampleBytes("ape/mono16-fast.ape")
        // The level is at 0 of the header, the bits at 16, the channels at 18.
        let changes: [(offset: Int, value: UInt16)] = [(0, 1_500), (0, 6_000), (16, 12), (16, 0), (18, 0), (18, 33)]
        for (offset, value) in changes {
            XCTAssertEqual(
                failure(decoding: try settingHeaderField(at: offset, to: value, in: bytes)),
                .unsupported(reason: OwnAudioWording.monkeysAudioShape), "field \(offset) = \(value)"
            )
        }
    }

    /// Bytes that do not start with the signature are not Monkey's Audio.
    func testOtherBytesAreNotMonkeysAudio() {
        XCTAssertEqual(failure(decoding: Array("RIFF....WAVEfmt ................".utf8)), .notThisFormat)
        XCTAssertEqual(failure(decoding: []), .notThisFormat)
        XCTAssertEqual(failure(decoding: Array("MAC ".utf8)), .notThisFormat)
    }

    /// A changed byte in a frame's audio fails the frame's CRC.
    func testAChangedByteIsDamage() throws {
        let bytes = try ownAudioSampleBytes("ape/stereo16-normal.ape")
        for offset in [bytes.count / 3, bytes.count / 2, bytes.count * 2 / 3] {
            var copy = bytes
            copy.replaceSubrange(offset..<offset + 1, with: [copy.dropFirst(offset).first.map { $0 ^ 0x01 } ?? 0])
            XCTAssertEqual(failure(decoding: copy), .damaged, "byte \(offset)")
        }
    }

    /// A file cut anywhere before its last few bytes is refused, with the
    /// CRCs and without them. (A frame ends in a few bytes of padding that
    /// a decoder never needs.)
    func testAFileCutAnywhereIsRefused() throws {
        let bytes = try ownAudioSampleBytes("ape/short16-normal.ape")
        for length in 0..<bytes.count - 8 {
            let cut = Array(bytes.prefix(length))
            XCTAssertNotNil(failure(decoding: cut), "cut at \(length)")
            XCTAssertNotNil(failure(decoding: cut, verifiesChecksums: false), "cut at \(length), no checksums")
        }
    }

    /// A header that promises frames the file does not hold, frames in an
    /// order no file has, or no frame at all, is damage; one that asks for
    /// frames too large to hold is refused.
    func testAHeaderNoFileHasIsRefused() throws {
        let bytes = try ownAudioSampleBytes("ape/mono16-fast.ape")
        // The count of frames is at 12 of the header (four bytes; the low two are set here).
        XCTAssertNotNil(failure(decoding: try settingHeaderField(at: 12, to: 0, in: bytes), verifiesChecksums: false))
        XCTAssertNotNil(failure(decoding: try settingHeaderField(at: 12, to: 60_000, in: bytes), verifiesChecksums: false))
        // The frames in a block are at 4 (four bytes): 33 million frames a block is past what is held.
        let huge = try settingHeaderField(at: 6, to: 0x0200, in: bytes)
        XCTAssertEqual(
            failure(decoding: huge, verifiesChecksums: false), .unsupported(reason: OwnAudioWording.monkeysAudioShape))
        // The SDK's own limits: over a million frames a block is refused below Insane, which may hold ten million.
        XCTAssertEqual(MonkeysAudioDecoder.mostFramesPerFrame(forLevel: 4_000), 1_000_000)
        XCTAssertEqual(MonkeysAudioDecoder.mostFramesPerFrame(forLevel: 5_000), 10_000_000)
        let overAMillion = try settingHeaderField(at: 6, to: 0x0010, in: bytes)
        XCTAssertEqual(
            failure(decoding: overAMillion, verifiesChecksums: false), .unsupported(reason: OwnAudioWording.monkeysAudioShape))
        let insane = try ownAudioSampleBytes("ape/mono32-insane.ape")
        XCTAssertNotEqual(
            failure(decoding: try settingHeaderField(at: 6, to: 0x0010, in: insane), verifiesChecksums: false),
            .unsupported(reason: OwnAudioWording.monkeysAudioShape))
        XCTAssertEqual(
            failure(decoding: try settingHeaderField(at: 6, to: 0x0099, in: insane), verifiesChecksums: false),
            .unsupported(reason: OwnAudioWording.monkeysAudioShape))
        // The two-frame file with its second frame's start set before its first's.
        var disordered = try ownAudioSampleBytes("ape/twoframes16-fast.ape")
        let header = Int(try XCTUnwrap(OwnAudioLittleEndian.uint32(disordered, 8)))
        let headerLength = Int(try XCTUnwrap(OwnAudioLittleEndian.uint32(disordered, 12)))
        let table = header + headerLength
        guard table + 8 <= disordered.count else { return XCTFail("The seek table lies outside the file") }
        disordered.replaceSubrange(table + 4..<table + 8, with: [1, 0, 0, 0])
        XCTAssertEqual(failure(decoding: disordered), .damaged)
    }

    // MARK: - The Pieces

    /// The compression levels and their filters; any other level has none.
    func testTheLevelsAndTheirFilters() {
        XCTAssertEqual(MonkeysAudioPredictor.filterShapes(forLevel: 1_000)?.count, 0)
        XCTAssertEqual(MonkeysAudioPredictor.filterShapes(forLevel: 2_000)?.map(\.order), [16])
        XCTAssertEqual(MonkeysAudioPredictor.filterShapes(forLevel: 3_000)?.map(\.order), [64])
        XCTAssertEqual(MonkeysAudioPredictor.filterShapes(forLevel: 4_000)?.map(\.order), [32, 256])
        XCTAssertEqual(MonkeysAudioPredictor.filterShapes(forLevel: 5_000)?.map(\.order), [16, 256, 1_280])
        XCTAssertNil(MonkeysAudioPredictor.filterShapes(forLevel: 0))
        XCTAssertNil(MonkeysAudioPredictor.filterShapes(forLevel: 2_500))
        XCTAssertNil(MonkeysAudioPredictor(level: 7_000, bitsPerSample: 16, isInterim: false))
    }

    /// A predictor gives the same samples again after it is reset, in each
    /// form: for files of up to 24 bits, for 32-bit files, and the interim
    /// form; and no residual, however large, traps.
    func testAPredictorStartsAfreshAfterAReset() throws {
        let residuals: [Int64] = [0, 5, -3, 1_000, -70_000, 123_456_789, Int64(Int32.max), Int64(Int32.min), 1 << 40, -(1 << 50)]
        for (bits, isInterim) in [(16, false), (24, false), (24, true), (32, false)] {
            var predictor = try XCTUnwrap(MonkeysAudioPredictor(level: 4_000, bitsPerSample: bits, isInterim: isInterim))
            // Enough values to roll every buffer.
            let first = (0..<600).map { predictor.decompress(residuals[$0 % residuals.count], other: Int64($0)) }
            predictor.reset()
            let second = (0..<600).map { predictor.decompress(residuals[$0 % residuals.count], other: Int64($0)) }
            XCTAssertEqual(first, second, "\(bits) bits, interim \(isInterim)")
        }
    }

    /// The range coder's tables are whole: 64 symbols that fill the range,
    /// and steps that double.
    func testTheRangeTables() {
        XCTAssertEqual(MonkeysAudioTables.rangeTotals.count, 65)
        XCTAssertEqual(MonkeysAudioTables.rangeWidths.count, 64)
        XCTAssertEqual(MonkeysAudioTables.rangeTotals.first, 0)
        XCTAssertEqual(MonkeysAudioTables.rangeTotals.last, 65_536)
        XCTAssertEqual(MonkeysAudioTables.rangeWidths.reduce(0, +), 65_536)
        XCTAssertEqual(MonkeysAudioTables.sumBoundaries.count, 32)
        XCTAssertEqual(Array(MonkeysAudioTables.sumBoundaries.prefix(4)), [0, 32, 64, 128])
    }

    /// A range decoder on bytes that are no frame ends in an error.
    func testARangeDecoderOnOtherBytesEndsInAnError() {
        for bytes in [[UInt8](), [1, 2, 3], [UInt8](repeating: 0, count: 64), [UInt8](repeating: 0xFF, count: 64)] {
            var decoder = MonkeysAudioRangeDecoder(bytes, startingAt: 0)
            var state = MonkeysAudioResidualState()
            do {
                _ = try decoder.word()
                try decoder.start()
                // More residuals than 64 bytes could hold.
                for _ in 0..<2_000 { _ = try decoder.residual(&state) }
                XCTFail("\(bytes.count) bytes held 2,000 residuals")
            } catch {
                XCTAssertEqual(error as? OwnAudioError, .damaged)
            }
        }
    }

    // MARK: - Hostile Files

    /// Damaged copies of every sample, from a fixed seed, each decode to
    /// samples or an error within a few seconds: every sample at least
    /// once, the multichannel, 24-bit stereo, pseudo-stereo, and two-frame
    /// files among them.
    func testDamagedFilesNeverTrap() throws {
        let samples = try ownAudioSamples(in: "ape")
        for name in ["eight16-high.ape", "stereo24-normal.ape", "pseudostereo16-normal.ape", "twoframes16-fast.ape"] {
            XCTAssertTrue(samples.contains { $0.fileName == name }, name)
        }
        let tried = try fuzzEverySample(in: "ape", seed: 20_261_117, seconds: 6)
        XCTAssertTrue(tried >= samples.count, "\(tried) damaged copies of \(samples.count) samples")
    }
}
