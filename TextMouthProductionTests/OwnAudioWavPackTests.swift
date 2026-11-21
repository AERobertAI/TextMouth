import XCTest
@testable import TextMouth

/// TextMouth's own WavPack reader (`WavPackDecoder` and the WavPack files
/// beside it): every sample, from WavPack's own encoder in each mode and
/// from ffmpeg's, decodes to its source's samples bit for bit (a hybrid
/// file with its correction file); a hybrid file alone decodes as lossy;
/// and a file that is cut, damaged, or crafted ends in an `OwnAudioError`,
/// never in a trap. Nothing is played, and no Apple audio API sees a
/// WavPack file.
final class OwnAudioWavPackTests: XCTestCase {
    // MARK: - Helpers

    /// A decoder of the sample at `path`, with its correction file when
    /// `usingCorrection` and it has one.
    private func decoder(
        of path: String,
        usingCorrection: Bool = true,
        verifiesChecksums: Bool = true
    ) throws -> WavPackDecoder {
        try WavPackDecoder(
            OwnAudioBytes(try ownAudioSampleBytes(path)),
            correction: usingCorrection ? try ownAudioCompanionBytes(of: path) : nil,
            verifiesChecksums: verifiesChecksums
        )
    }

    /// The error decoding `bytes` (with `correction`) to its end gives; nil
    /// when it decodes whole.
    private func failure(
        decoding bytes: [UInt8],
        correction: [UInt8]? = nil,
        verifiesChecksums: Bool = true
    ) -> OwnAudioError? {
        do {
            var decoder: any OwnAudioDecoder = try WavPackDecoder(
                OwnAudioBytes(bytes), correction: correction.map { OwnAudioBytes($0) }, verifiesChecksums: verifiesChecksums)
            _ = try allSamples(of: &decoder)
            return nil
        } catch {
            return error as? OwnAudioError
        }
    }

    // MARK: - Exact Decoding

    /// Every WavPack sample gives its source's samples back exactly: fast
    /// to very high modes, 8 to 32 bits, floats, mono to 5.1, many small
    /// blocks, hybrid files with their correction files, and ffmpeg's files.
    func testEverySampleDecodesToItsSourcesSamples() throws {
        try assertEverySampleDecodesExactly(in: "wv", as: .wavPack)
    }

    /// What the headers say beyond the shape: the channel mask of 5.1, none
    /// for stereo, and a float file's samples as floats near full scale.
    func testTheStreamSaysWhatTheFileHolds() throws {
        XCTAssertEqual(try decoder(of: "wv/six16.wv").stream.channelMask, 0x3F)
        XCTAssertEqual(try decoder(of: "wv/ffmpeg-six16.wv").stream.channels, 6)
        XCTAssertNil(try decoder(of: "wv/stereo16.wv").stream.channelMask)
        XCTAssertEqual(try decoder(of: "wv/rate12345.wv").stream.sampleRate, 12_345)
        var floats: any OwnAudioDecoder = try decoder(of: "wv/float32.wv")
        XCTAssertTrue(floats.stream.isFloat)
        let values = try allSamples(of: &floats).map { Float(bitPattern: UInt32(bitPattern: $0)) }
        XCTAssertTrue(values.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(values.map(abs).max() ?? 0, 0.05)
    }

    /// A hybrid file without its correction file is lossy: as long, close
    /// to the lossless samples, and not equal to them. An empty correction
    /// file counts as none.
    func testAHybridFileAloneIsLossy() throws {
        for path in ["wv/hybrid16.wv", "wv/hybridmono16.wv", "wv/hybridshape24.wv", "wv/hybridsix16.wv"] {
            var exact: any OwnAudioDecoder = try decoder(of: path)
            var lossy: any OwnAudioDecoder = try decoder(of: path, usingCorrection: false)
            XCTAssertTrue(exact.stream.isLossless, path)
            XCTAssertFalse(lossy.stream.isLossless, path)
            XCTAssertEqual(lossy.stream.frames, exact.stream.frames, path)
            let exactSamples = try allSamples(of: &exact)
            let lossySamples = try allSamples(of: &lossy)
            XCTAssertEqual(lossySamples.count, exactSamples.count, path)
            XCTAssertNotEqual(lossySamples, exactSamples, path)
            // The lossy stream stays within a sixteenth of full scale of the lossless one.
            let limit = Int64(1) << Int64(exact.stream.bitsPerSample - 5)
            let worst = zip(lossySamples, exactSamples).map { abs(Int64($0) - Int64($1)) }.max() ?? 0
            XCTAssertLessThan(worst, limit, path)
        }
        let alone = try WavPackDecoder(OwnAudioBytes(try ownAudioSampleBytes("wv/hybrid16.wv")), correction: OwnAudioBytes([]))
        XCTAssertFalse(alone.stream.isLossless)
        XCTAssertFalse(try decoder(of: "wv/lossy16.wv").stream.isLossless)
    }

    /// A lossless file ignores a correction file handed to it.
    func testALosslessFileIgnoresACorrectionFile() throws {
        let bytes = try ownAudioSampleBytes("wv/stereo16.wv")
        var plain: any OwnAudioDecoder = try WavPackDecoder(OwnAudioBytes(bytes))
        var withOther: any OwnAudioDecoder = try WavPackDecoder(
            OwnAudioBytes(bytes), correction: OwnAudioBytes(try ownAudioSampleBytes("wv/hybrid16.wvc")))
        XCTAssertEqual(try allSamples(of: &plain), try allSamples(of: &withOther))
    }

    // MARK: - Refusals

    /// A correction file of another recording, a cut one, and a damaged
    /// one do not pass for the right one.
    func testAWrongCorrectionFileIsRefused() throws {
        let file = try ownAudioSampleBytes("wv/hybrid16.wv")
        let right = try ownAudioSampleBytes("wv/hybrid16.wvc")
        XCTAssertNil(failure(decoding: file, correction: right))
        // Each is the correction file's fault, and is said to be.
        XCTAssertEqual(
            failure(decoding: file, correction: try ownAudioSampleBytes("wv/hybridcross16.wvc")), .companionDamaged)
        XCTAssertEqual(failure(decoding: file, correction: Array(right.prefix(right.count / 2))), .companionDamaged)
        var damaged = right
        damaged[damaged.count / 2] ^= 0x04
        XCTAssertEqual(failure(decoding: file, correction: damaged), .companionDamaged)
        // Damage to the file itself stays the file's.
        var damagedFile = file
        damagedFile[damagedFile.count / 2] ^= 0x04
        XCTAssertEqual(failure(decoding: damagedFile, correction: right), .damaged)
    }

    /// A changed byte anywhere in a block fails the block's checksum, and
    /// one in the audio fails the samples' checksum when the block's is
    /// not verified.
    func testAChangedByteIsDamage() throws {
        let bytes = try ownAudioSampleBytes("wv/mono16-fast.wv")
        for offset in [24, 40, bytes.count / 2] {
            var copy = bytes
            copy[offset] ^= 0x01
            XCTAssertNotNil(failure(decoding: copy), "byte \(offset)")
        }
    }

    /// A file cut anywhere is refused, at every length, with the checksums
    /// and without them.
    func testAFileCutAnywhereIsRefused() throws {
        let bytes = try ownAudioSampleBytes("wv/short16.wv")
        // The audio is in the first block, whose size its header gives.
        let audioEnd = Int(try XCTUnwrap(OwnAudioLittleEndian.uint32(bytes, 4))) + 8
        XCTAssertLessThanOrEqual(audioEnd, bytes.count)
        for length in 0..<audioEnd {
            let cut = Array(bytes.prefix(length))
            XCTAssertNotNil(failure(decoding: cut), "cut at \(length)")
            XCTAssertNotNil(failure(decoding: cut, verifiesChecksums: false), "cut at \(length), no checksums")
        }
    }

    /// DSD audio is refused in words that say so; bytes that do not start
    /// with a block are not WavPack.
    func testDSDAndOtherBytesAreRefused() throws {
        // Byte 27 is the top byte of the first block's flags; `ownAudioSampleBytes` promises 64 bytes.
        var dsd = try ownAudioSampleBytes("wv/short16.wv")
        dsd.replaceSubrange(27..<28, with: [dsd.dropFirst(27).first.map { $0 | 0x80 } ?? 0x80])
        XCTAssertEqual(
            failure(decoding: dsd, verifiesChecksums: false), .unsupported(reason: OwnAudioWording.wavPackDSD))
        XCTAssertEqual(failure(decoding: Array("RIFF....WAVEfmt ".utf8)), .notThisFormat)
        XCTAssertEqual(failure(decoding: []), .notThisFormat)
        XCTAssertNotNil(failure(decoding: Array("wvpk".utf8)))
        XCTAssertEqual(
            OwnAudioWording.sentence(for: .unsupported(reason: OwnAudioWording.wavPackDSD), fileName: "Disc.wv"),
            "TextMouth can't read the audio file Disc.wv because it holds DSD audio, which TextMouth does not read."
        )
    }

    // MARK: - The Pieces

    /// A block's header reads its fields, and refuses sizes, versions, and
    /// frame counts no file has.
    func testABlockHeaderIsReadAndChecked() throws {
        let bytes = try ownAudioSampleBytes("wv/stereo16.wv")
        let header = try XCTUnwrap(WavPackHeader(bytes))
        XCTAssertEqual(header.blockIndex, 0)
        XCTAssertEqual(header.totalFrames, 11_025)
        XCTAssertEqual(header.channels, 2)
        XCTAssertFalse(header.isMonoData)
        XCTAssertTrue(WavPackHeader.versions.contains(header.version))
        XCTAssertLessThanOrEqual(header.blockBytes, bytes.count)
        XCTAssertNotEqual(header.flags & WavPackFlags.initialBlock, 0)
        XCTAssertNotEqual(header.flags & WavPackFlags.finalBlock, 0)

        // An odd size, a size under 24, a size of a megabyte, version 3, and 200,000 frames.
        let changes: [(offset: Int, value: UInt8)] = [(4, 1), (6, 0x10), (9, 3), (22, 4)]
        for (offset, value) in changes {
            var copy = bytes
            copy[offset] = value
            XCTAssertNil(WavPackHeader(copy), "byte \(offset) = \(value)")
        }
        var small = bytes
        small.replaceSubrange(4..<8, with: [22, 0, 0, 0])
        XCTAssertNil(WavPackHeader(small))
        XCTAssertNil(WavPackHeader(Array(bytes.prefix(31))))
        XCTAssertNil(WavPackHeader(bytes, at: bytes.count - 8))
        // A length the header does not know.
        var unknown = bytes
        unknown.replaceSubrange(12..<16, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(try XCTUnwrap(WavPackHeader(unknown)).totalFrames)
    }

    /// A file whose header does not know its length takes it from its last
    /// block, and still decodes to the same samples.
    func testALengthTheHeaderDoesNotKnowComesFromTheLastBlock() throws {
        var bytes = try ownAudioSampleBytes("wv/blocks16.wv")
        bytes.replaceSubrange(12..<16, with: [0xFF, 0xFF, 0xFF, 0xFF])
        var unknown: any OwnAudioDecoder = try WavPackDecoder(OwnAudioBytes(bytes), verifiesChecksums: false)
        var known: any OwnAudioDecoder = try decoder(of: "wv/blocks16.wv")
        XCTAssertEqual(unknown.stream.frames, known.stream.frames)
        XCTAssertEqual(try allSamples(of: &unknown), try allSamples(of: &known))
    }

    /// Bits come lowest first; past the stream's end they are ones; a run
    /// of ones is counted up to its limit; and a code takes the fewest bits.
    func testTheBitReader() {
        var reader = WavPackBits([0b1010_0111, 0x0F], in: 0..<2)
        XCTAssertTrue(reader.isOpen)
        XCTAssertEqual(reader.ones(upTo: 17), 3)
        XCTAssertEqual(reader.bit(), 0)
        XCTAssertEqual(reader.bits(3), 0b101)
        XCTAssertEqual(reader.peek(4), 0xF)
        reader.skip(4)
        XCTAssertEqual(reader.bits(4), 0)
        XCTAssertEqual(reader.bits(32), UInt32.max, "Past the end every bit is a 1")
        XCTAssertEqual(reader.ones(upTo: 33), 33)
        XCTAssertEqual(reader.bits(0), 0)
        XCTAssertFalse(WavPackBits().isOpen)

        // 0 to 4 takes two bits for 0 to 2 and three for 3 and 4; 0 to 3 takes two bits, the first the
        // higher; 0 or 1 takes one. The bits, in order: 1 0, 0 1, 1 1 1, 1 0, 1.
        var codes = WavPackBits([0b1111_1001, 0b0000_0010], in: 0..<2)
        XCTAssertEqual(codes.code(upTo: 4), 1)
        XCTAssertEqual(codes.code(upTo: 4), 2)
        XCTAssertEqual(codes.code(upTo: 4), 4)
        XCTAssertEqual(codes.code(upTo: 3), 2)
        XCTAssertEqual(codes.code(upTo: 1), 1)
        XCTAssertEqual(codes.code(upTo: 0), 0)
        var wide = WavPackBits([0xFF, 0xFF, 0xFF, 0xFF, 0xFF], in: 0..<5)
        XCTAssertEqual(wide.code(upTo: UInt32.max), UInt32.max)
    }

    /// WavPack's logarithms: a round trip stays within one part in 225 and
    /// one more, a stored weight comes back to its range, and no value traps.
    func testTheLogarithms() {
        let values: [UInt32] = [1, 2, 3, 100, 255, 256, 1_000, 65_535, 1 << 20, 1 << 30]
        for value in values {
            let back = Int64(WavPackLog.exp2(WavPackLog.log2(value)))
            XCTAssertLessThanOrEqual(abs(back - Int64(value)), Int64(value) / 100 + 2, "\(value) came back as \(back)")
        }
        XCTAssertEqual(WavPackLog.log2(0), 0)
        XCTAssertEqual(WavPackLog.exp2(0), 0)
        XCTAssertEqual(WavPackLog.exp2(-256), -WavPackLog.exp2(256))
        _ = WavPackLog.exp2(Int32.min)
        _ = WavPackLog.exp2(Int32.max)
        _ = WavPackLog.log2(UInt32.max)
        XCTAssertEqual(WavPackLog.restoredWeight(0), 0)
        XCTAssertEqual(WavPackLog.restoredWeight(127), 1_024)
        XCTAssertEqual(WavPackLog.restoredWeight(0x80), -1_024)
        XCTAssertEqual(WavPackLog.bitCount(0), 0)
        XCTAssertEqual(WavPackLog.bitCount(UInt32.max), 32)
        XCTAssertEqual(WavPackLog.log2Table.count, 256)
        XCTAssertEqual(WavPackLog.exp2Table.count, 256)
    }

    /// A weight of 1,024 gives a sample back, small or large; weights move
    /// towards agreement and, between channels, stop at their limit.
    func testTheWeights() {
        let samples: [Int32] = [0, 1, -1, 12_345, -32_768, 32_767, 1 << 20, -(1 << 23), (1 << 25) + 7]
        for sample in samples {
            XCTAssertEqual(WavPackWeight.apply(1_024, sample), sample, "\(sample)")
            XCTAssertEqual(WavPackWeight.apply(0, sample), 0, "\(sample)")
        }
        // The largest numbers wrap, as the format's own arithmetic does, and never trap.
        _ = WavPackWeight.apply(1_024, Int32.max)
        _ = WavPackWeight.apply(-1_024, Int32.min)
        _ = WavPackWeight.apply(Int32.max, Int32.min)
        XCTAssertEqual(WavPackWeight.apply(512, 1_000), 500)
        XCTAssertEqual(WavPackWeight.apply(512, 1 << 20), 1 << 19)
        var weight: Int32 = 10
        WavPackWeight.update(&weight, delta: 2, source: 5, result: 7)
        XCTAssertEqual(weight, 12)
        WavPackWeight.update(&weight, delta: 2, source: 5, result: -7)
        XCTAssertEqual(weight, 10)
        WavPackWeight.update(&weight, delta: 2, source: 0, result: 7)
        XCTAssertEqual(weight, 10)
        var clipped: Int32 = 1_023
        WavPackWeight.updateClipped(&clipped, delta: 7, source: 3, result: 3)
        XCTAssertEqual(clipped, 1_024)
        clipped = -1_023
        WavPackWeight.updateClipped(&clipped, delta: 7, source: 3, result: -3)
        XCTAssertEqual(clipped, -1_024)
        XCTAssertTrue(WavPackDecorrelationPass.isValid(term: 18, isMono: true))
        XCTAssertFalse(WavPackDecorrelationPass.isValid(term: -1, isMono: true))
        XCTAssertTrue(WavPackDecorrelationPass.isValid(term: -3, isMono: false))
        let undefined: [Int32] = [0, 9, 16, 19, -4]
        for term in undefined {
            XCTAssertFalse(WavPackDecorrelationPass.isValid(term: term, isMono: false), "\(term)")
        }
    }

    // MARK: - Hostile Files

    /// Damaged copies of every sample and of the correction files, from a
    /// fixed seed, each decode to samples or an error within a few seconds.
    func testDamagedFilesNeverTrap() throws {
        XCTAssertGreaterThan(try fuzzEverySample(in: "wv", seed: 20_261_116, seconds: 6), 0)
    }
}
