import XCTest
@testable import TextMouth

/// The formats TextMouth's own audio readers read, at import
/// (`OwnAudioConverter`, through `ImportAudioConverter`): each is known by
/// its bytes, decoded in the app, and written as Apple Lossless that holds
/// the source's samples exactly, with its tags; a lossy WavPack file
/// becomes AAC; a file a reader refuses fails the import in words that say
/// why. Nothing is played. The only files Apple's audio frameworks open
/// here are the .m4a files the conversion wrote.
final class OwnAudioImportTests: XCTestCase {
    private var folder: URL! // lint-ok: made in setUpWithError before every test
    /// Imported book packages, removed when a test ends.
    private var importedPackages: [URL] = []

    /// The folders of `TestData/format-samples` that hold the own readers'
    /// samples, each with its `pcm.tsv`.
    private static let sampleFolders = ["tta", "wv", "ape"]

    override func setUpWithError() throws {
        folder = try makeSandboxDirectory("OwnAudioImport")
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        folder = nil
    }

    // MARK: - Helpers

    /// Copies the format sample at `path` into a new folder inside the
    /// test's own (or `destination`), named `name` when given, with its
    /// companion (a WavPack correction file) beside it under the same name
    /// unless `alone`.
    @discardableResult
    private func copySample(
        _ path: String,
        as name: String? = nil,
        into destination: URL? = nil,
        alone: Bool = false
    ) throws -> URL {
        let target = destination ?? folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = try requireFile("format-samples/\(path)")
        let copy = target.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        if !alone, let companion = ownAudioCompanionPath(of: path) {
            let ending = (companion as NSString).pathExtension
            try FileManager.default.copyItem(
                at: try requireFile("format-samples/\(companion)"),
                to: copy.deletingPathExtension().appendingPathExtension(ending)
            )
        }
        return copy
    }

    /// Writes `bytes` as a file named `name` in a new folder of the test's own.
    private func writeFile(_ bytes: [UInt8], named name: String) throws -> URL {
        let target = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let url = target.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// What the conversion should write of the sample at `path`: the
    /// samples its own reader gives (with its companion), floats made
    /// 24-bit whole numbers, more than two channels mixed to stereo, each
    /// moved to the top of 32 bits as `samplesOfConvertedFile(at:)` (Mac only) gives
    /// them.
    private func samplesToBeWritten(of path: String) throws -> [Int32] {
        let bytes = OwnAudioBytes(try ownAudioSampleBytes(path))
        let format = try XCTUnwrap(OwnAudioFormat.of(bytes), path)
        var decoder = try format.decoder(of: bytes, companion: try ownAudioCompanionBytes(of: path))
        let stream = decoder.stream
        var samples = try allSamples(of: &decoder)
        var bits = stream.bitsPerSample
        if stream.isFloat {
            samples = OwnAudioSamples.wholeNumbers(fromFloats: samples)
            bits = OwnAudioSamples.bitsForFloats
        }
        if stream.channels > 2 {
            samples = OwnAudioSamples.stereo(
                samples, gains: OwnAudioSamples.stereoGains(channels: stream.channels, mask: stream.channelMask ?? 0))
        }
        return samples.map { $0 << Int32(32 - bits) }
    }

    /// The failure converting `source` ends in.
    private func conversionFailure(of source: URL) async -> ImportAudioConverter.Failure? {
        do {
            _ = try await ImportAudioConverter.convert(source)
            return nil
        } catch {
            return error as? ImportAudioConverter.Failure
        }
    }

    /// The text of the file `name` in the app's Licenses folder `folder`.
    private func licenceText(_ folder: String, _ name: String) throws -> String {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        return try String(contentsOf: resources.appendingPathComponent("Licenses/\(folder)/\(name)"), encoding: .utf8)
    }

    // MARK: - Which Files

    /// The own readers' extensions are converted at import, are audiobook
    /// extensions that Open Book offers, are never decoded in the app by
    /// Apple's readers, and are no tracks of a package.
    func testTheExtensionsAreImportOnlyAudio() {
        XCTAssertEqual(ImportAudioConverter.ownReaderExtensions, OwnAudioFormat.allFileExtensions)
        XCTAssertEqual(ImportAudioConverter.ownReaderExtensions, ["tta", "wv", "ape"])
        for ext in ImportAudioConverter.ownReaderExtensions {
            let url = URL(fileURLWithPath: "/a/Track.\(ext.uppercased())")
            XCTAssertTrue(ImportAudioConverter.isConvertedAtImport(url), ext)
            XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(url), ext)
            XCTAssertEqual(ImportAudioConverter.verdict(for: url), .convert, ext)
            XCTAssertEqual(BookFormat.detect(from: url), .audio, ext)
            XCTAssertTrue(ArchiveEntryLimits.isAudio("Disc/track.\(ext)"), ext)
            XCTAssertFalse(BookFormat.packageTrackExtensions.contains(ext), ext)
            XCTAssertTrue(ImportAudioConverter.importOnlyExtensions.contains(ext), ext)
            XCTAssertNotNil(documentType(listing: ext), "No document type lists .\(ext)")
        }
        XCTAssertTrue(ImportAudioConverter.importOnlyExtensions.isSuperset(of: ImportAudioConverter.coreAudioExtensions))
        XCTAssertTrue(ImportAudioConverter.ownReaderExtensions.isDisjoint(with: ImportAudioConverter.coreAudioExtensions))
        // A correction file is no track and no book.
        XCTAssertNil(BookFormat.detect(from: URL(fileURLWithPath: "/a/Track.wvc")))
        XCTAssertFalse(ArchiveEntryLimits.isAudio("Disc/track.wvc"))
    }

    /// Each format has a name a listener hears.
    func testEachFormatHasAName() {
        XCTAssertEqual(OwnAudioFormat.trueAudio.displayName, "True Audio")
        XCTAssertEqual(OwnAudioFormat.wavPack.displayName, "WavPack")
        XCTAssertEqual(OwnAudioFormat.monkeysAudio.displayName, "Monkey's Audio")
        XCTAssertEqual(OwnAudioFormat.wavPack.companionExtension, "wvc")
        XCTAssertNil(OwnAudioFormat.trueAudio.companionExtension)
        for format in OwnAudioFormat.allCases {
            XCTAssertFalse(format.fileExtensions.isEmpty)
            XCTAssertFalse(format.signatures.isEmpty)
            XCTAssertTrue(format.signatures.allSatisfy { $0.utf8.count == 4 })
            XCTAssertEqual(format.formatID.count, 4)
        }
    }

    /// The iPhone's import refuses none of these formats, which the app decodes itself as the
    /// Mac's does: not by content, with any name, and not by name alone, a file whose bytes
    /// are of none of them failing the conversion as unreadable (never sending anyone to a
    /// Mac) on both platforms. A file of another format that the phone cannot convert is
    /// still refused, among them.
    func testTheIPhoneRefusesNoFileOfTheOwnReaders() throws {
        var files: [URL] = []
        for (path, name) in [("tta/mono16.tta", "A.mp3"), ("wv/hybridmono16.wv", "B.m4a"), ("ape/mono16-fast.ape", "C.APE"),
                             ("tta/stereo16.tta", "D.tta"), ("wv/stereo16.wv", "E.wv")] {
            files.append(try copySample(path, as: name))
        }
        // A file named for a format whose bytes are of none of them (or nothing at all) is let by too.
        files.append(try writeFile([UInt8](repeating: 0x41, count: 64), named: "Noise.tta"))
        files.append(URL(fileURLWithPath: "/nonexistent/Gone.wv"))
        for file in files {
            XCTAssertTrue(PhoneImportRefusal.isReadByOwnReader(file), file.lastPathComponent)
        }
        XCTAssertNoThrow(try PhoneImportRefusal.refuseConversion(of: files))
        // What the phone can't convert is refused still, whatever it is among.
        let ogg = URL(fileURLWithPath: "/nonexistent/Radio Drama.ogg")
        XCTAssertFalse(PhoneImportRefusal.isReadByOwnReader(ogg))
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: files + [ogg])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .convertedAudio(kind: "Ogg"))
        }
    }

    /// A file of another format the import converts, named like one of the own readers' formats,
    /// is refused as what it is, with the true sentence ("is in Ogg ... Add it on your Mac"), not
    /// let by its name to fail as unreadable: Ogg's signature, and an AC-3 sample, each so named.
    func testAnotherFormatNamedLikeAnOwnReadersIsRefusedAsWhatItIs() throws {
        let ogg = try writeFile(Array("OggS".utf8) + [UInt8](repeating: 0, count: 60), named: "Talk.tta")
        let ac3 = try copySample("ac3/tones.ac3", as: "Notes.wv")
        XCTAssertFalse(PhoneImportRefusal.isReadByOwnReader(ogg))
        XCTAssertFalse(PhoneImportRefusal.isReadByOwnReader(ac3))
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: [ogg])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .convertedAudio(kind: "Ogg"))
        }
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: [ac3])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .convertedAudio(kind: "AC-3"))
        }
        // An old WavPack file (a WAVE file's start) is still let by its name, to say why it can't be read.
        let wave: [UInt8] = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVEfmt ".utf8) + [UInt8](repeating: 0, count: 64)
        XCTAssertTrue(PhoneImportRefusal.isReadByOwnReader(try writeFile(wave, named: "Old.wv")))
    }

    /// A file named for a format of the own readers, whose bytes are of none of them, is
    /// unreadable as a file afinfo can't read is (the Mac's own failure), also on the
    /// iPhone, which has no afinfo: not "not available on iPhone yet".
    func testAFileNamedForAFormatButOfNoneIsUnreadable() async throws {
        for name in ["Noise.tta", "Noise.wv", "Noise.ape"] {
            let file = try writeFile([UInt8](repeating: 0x41, count: 64), named: name)
            let failure = await conversionFailure(of: file)
            XCTAssertEqual(failure, .unreadable(fileName: name), name)
            XCTAssertEqual(namesOfFiles(in: file.deletingLastPathComponent()), [name], name)
        }
    }

    /// A file is known by its bytes whatever it is named, also behind an
    /// ID3v2 tag, short or longer than the sniffer's window; the content's
    /// verdict is to convert it.
    func testAFileIsKnownByItsBytes() throws {
        let plain = try copySample("tta/mono16.tta", as: "plain.mp3")
        XCTAssertEqual(AudioContentSniffer.kind(of: plain), .ownReader(.trueAudio))
        XCTAssertEqual(ImportAudioConverter.verdict(for: plain), .convert)
        XCTAssertEqual(OwnAudioConverter.format(of: plain), .trueAudio)
        XCTAssertFalse(ImportAudioConverter.isConvertedAtImport(plain), "The extension alone says nothing")

        let tagged = try copySample("tta/tagged16.tta", as: "tagged.m4a")
        XCTAssertEqual(AudioContentSniffer.kind(of: tagged), .ownReader(.trueAudio))
        XCTAssertEqual(OwnAudioConverter.format(of: tagged), .trueAudio)

        let wavPack = try copySample("wv/stereo16.wv", as: "music.flac")
        XCTAssertEqual(AudioContentSniffer.kind(of: wavPack), .ownReader(.wavPack))
        XCTAssertEqual(OwnAudioConverter.format(of: wavPack), .wavPack)
        for path in ["ape/stereo16-normal.ape", "ape/float32-fast.ape"] {
            let monkeys = try copySample(path, as: "music.wav")
            XCTAssertEqual(AudioContentSniffer.kind(of: monkeys), .ownReader(.monkeysAudio), path)
            XCTAssertEqual(OwnAudioConverter.format(of: monkeys), .monkeysAudio, path)
        }

        // A tag longer than the sniffer's first window, as cover art makes it.
        let audio = try ownAudioSampleBytes("tta/mono16.tta")
        let size = AudioContentSniffer.windowLength + 5_000
        var long: [UInt8] = Array("ID3".utf8) + [3, 0, 0]
        long += [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
        long += [UInt8](repeating: 0, count: size)
        let longFile = try writeFile(long + audio, named: "long-tag.tta")
        XCTAssertEqual(AudioContentSniffer.kind(of: longFile), .ownReader(.trueAudio))
        XCTAssertEqual(OwnAudioConverter.format(of: longFile), .trueAudio)

        // Other audio is none of the own readers' formats.
        let other = try requireFile("format-samples/mp3-chapters/three-tones.mp3")
        XCTAssertNil(OwnAudioConverter.format(of: other))
        XCTAssertNil(OwnAudioConverter.format(of: folder.appendingPathComponent("missing.tta")))
        XCTAssertNil(try OwnAudioConverter.sourceInfo(of: other))
    }

    // MARK: - Licences

    /// The notices of the decoders the readers follow ship inside the app:
    /// the TTA Hardware Players Library's README, which holds its BSD
    /// licence, WavPack's COPYING, and the Monkey's Audio SDK's License.txt.
    func testTheReadersNoticesShipWithTheApp() throws {
        let trueAudio = try licenceText("TrueAudio", "README")
        XCTAssertTrue(trueAudio.contains("(c) 2004 Alexander Djourik"), String(trueAudio.prefix(120)))
        XCTAssertTrue(trueAudio.contains("Redistributions in binary form must reproduce the above copyright"))
        XCTAssertTrue(trueAudio.contains("True Audio Software"))
        // The sources the reader follows name another holder than the README: their own notice ships too.
        let sourceNotice = try licenceText("TrueAudio", "COPYRIGHT")
        XCTAssertTrue(sourceNotice.contains("Copyright (c) 2004 True Audio Software. All rights reserved."))
        XCTAssertTrue(sourceNotice.contains("Redistributions in binary form must reproduce the above copyright"))
        let wavPack = try licenceText("WavPack", "COPYING")
        XCTAssertTrue(wavPack.contains("David Bryant"), String(wavPack.prefix(120)))
        XCTAssertTrue(wavPack.contains("Redistributions in binary form must reproduce the above copyright"))
        let monkeysAudio = try licenceText("MonkeysAudio", "License.txt")
        XCTAssertTrue(monkeysAudio.contains("Matthew T. Ashland"), String(monkeysAudio.prefix(120)))
        XCTAssertTrue(monkeysAudio.contains("Redistributions in binary form must reproduce the above copyright"))
    }

    // MARK: - What the Converter Knows of a Source

    /// A True Audio source is described by its own reader: lossless, at its
    /// own depth, converted in the app, and planned as Apple Lossless.
    func testASourceIsDescribedByItsReader() async throws {
        let source = try copySample("tta/stereo24.tta")
        let read = try await ImportAudioConverter.inspect(source)
        let info = try XCTUnwrap(read)
        XCTAssertEqual(info.formatID, "tta1")
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.bitsPerSample, 24)
        XCTAssertEqual(info.duration, 0.25, accuracy: 1e-9)
        XCTAssertTrue(info.isLossless)
        XCTAssertTrue(info.hasChannelLayout)
        XCTAssertEqual(info.ownReader, .trueAudio)
        XCTAssertEqual(ImportAudioConverter.plan(for: source, info: info), .convertToAppleLossless)
        let target = ImportAudioConverter.target(for: info, bytes: 1_000)
        XCTAssertEqual(target.appleLosslessBitDepth, 24)
        XCTAssertEqual(target.channels, 2)

        // Six channels with no layout cannot be mixed to stereo; WavPack's 5.1 names its layout.
        let six = try copySample("tta/six16.tta")
        let sixRead = try await ImportAudioConverter.inspect(six)
        XCTAssertEqual(sixRead?.hasChannelLayout, false)
        XCTAssertEqual(sixRead?.channels, 6)
        let surround = try copySample("wv/six16.wv")
        let surroundRead = try await ImportAudioConverter.inspect(surround)
        XCTAssertEqual(surroundRead?.hasChannelLayout, true)
        XCTAssertEqual(surroundRead?.ownReader, .wavPack)
    }

    /// A hybrid WavPack file is lossless with its correction file beside
    /// it and lossy alone; floats have no bit depth, so they are written
    /// at 24 bits.
    func testAHybridFileIsLosslessOnlyWithItsCorrectionFile() async throws {
        let together = try copySample("wv/hybrid16.wv")
        let togetherRead = try await ImportAudioConverter.inspect(together)
        let togetherInfo = try XCTUnwrap(togetherRead)
        XCTAssertTrue(togetherInfo.isLossless)
        XCTAssertEqual(ImportAudioConverter.plan(for: together, info: togetherInfo), .convertToAppleLossless)
        XCTAssertEqual(OwnAudioConverter.companion(of: together)?.lastPathComponent, "hybrid16.wvc")

        let alone = try copySample("wv/hybrid16.wv", alone: true)
        let aloneRead = try await ImportAudioConverter.inspect(alone)
        let aloneInfo = try XCTUnwrap(aloneRead)
        XCTAssertFalse(aloneInfo.isLossless)
        XCTAssertEqual(ImportAudioConverter.plan(for: alone, info: aloneInfo), .convertToAAC)
        XCTAssertNil(OwnAudioConverter.companion(of: alone))

        let floats = try copySample("wv/float32.wv")
        let floatsRead = try await ImportAudioConverter.inspect(floats)
        let floatsInfo = try XCTUnwrap(floatsRead)
        XCTAssertNil(floatsInfo.bitsPerSample)
        XCTAssertTrue(floatsInfo.isLossless)
        XCTAssertEqual(ImportAudioConverter.target(for: floatsInfo, bytes: 1).appleLosslessBitDepth, 24)
    }

    /// A stream's description: floats have no bit depth, a lossy stream is
    /// not lossless, and more than two channels have a layout only with a
    /// mask.
    func testAStreamsDescription() {
        XCTAssertEqual([16, 20, 24, 32].map(OwnAudioConverter.writtenBitDepth(forAppleLossless:)), [16, 24, 24, 32])
        let float = OwnAudioStream(sampleRate: 44_100, channels: 2, bitsPerSample: 32, isFloat: true, frames: 44_100)
        let floatInfo = OwnAudioConverter.sourceInfo(for: float, format: .wavPack)
        XCTAssertNil(floatInfo.bitsPerSample)
        XCTAssertEqual(floatInfo.duration, 1)
        XCTAssertEqual(floatInfo.formatID, "wvpk")

        let lossy = OwnAudioStream(sampleRate: 44_100, channels: 2, bitsPerSample: 16, isLossless: false, frames: 441_000)
        let lossyInfo = OwnAudioConverter.sourceInfo(for: lossy, format: .wavPack)
        XCTAssertFalse(lossyInfo.isLossless)
        XCTAssertNil(ImportAudioConverter.target(for: lossyInfo, bytes: 160_000).appleLosslessBitDepth)

        let masked = OwnAudioStream(sampleRate: 48_000, channels: 6, bitsPerSample: 16, frames: 10, channelMask: 0x3F)
        XCTAssertTrue(OwnAudioConverter.sourceInfo(for: masked, format: .wavPack).hasChannelLayout)
        let unmasked = OwnAudioStream(sampleRate: 48_000, channels: 6, bitsPerSample: 16, frames: 10)
        XCTAssertFalse(OwnAudioConverter.sourceInfo(for: unmasked, format: .trueAudio).hasChannelLayout)
        XCTAssertEqual(OwnAudioStream(sampleRate: 0, channels: 1, bitsPerSample: 16, frames: 10).duration, 0)
    }

    /// A companion is the file of the same name with the companion's
    /// extension, in either case, and only a format that has one has any.
    func testACompanionIsFoundByItsName() throws {
        let target = folder.appendingPathComponent("Companions")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["a.wv", "a.wvc", "b.WV", "b.WVC", "c.wv", "d.tta", "d.wvc", "e.mp3", "e.wvc"] {
            try Data([1]).write(to: target.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: target.appendingPathComponent("f.wvc"), withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("f.wv"))
        XCTAssertEqual(OwnAudioConverter.companion(of: target.appendingPathComponent("a.wv"))?.lastPathComponent, "a.wvc")
        XCTAssertEqual(
            OwnAudioConverter.companion(of: target.appendingPathComponent("b.WV"))?.lastPathComponent.lowercased(), "b.wvc")
        XCTAssertNil(OwnAudioConverter.companion(of: target.appendingPathComponent("c.wv")))
        XCTAssertNil(OwnAudioConverter.companion(of: target.appendingPathComponent("d.tta")))
        XCTAssertNil(OwnAudioConverter.companion(of: target.appendingPathComponent("e.mp3")))
        XCTAssertNil(OwnAudioConverter.companion(of: target.appendingPathComponent("f.wv")), "A folder is no companion")
    }

    // MARK: - Converting

    /// Every lossless sample of every reader converts to an .m4a of Apple
    /// Lossless at its own depth and rate that plays, and the samples in it
    /// are the source's, every one: floats as 24-bit whole numbers, and 5.1
    /// as the stereo mix made here.
    func testEverySampleConvertsToAppleLosslessThatHoldsItsSamplesExactly() async throws {
        for sampleFolder in Self.sampleFolders {
            for sample in try ownAudioSamples(in: sampleFolder) where sample.isLossless {
                // Six channels that name no layout are refused (see below).
                guard sample.channels <= 2 || sampleFolder == "wv" else { continue }
                let source = try copySample(sample.path)
                let conversion = try await ImportAudioConverter.convert(source)

                XCTAssertEqual(
                    conversion.converted.lastPathComponent, source.deletingPathExtension().lastPathComponent + ".m4a")
                XCTAssertNil(conversion.bitRate, sample.path)
                XCTAssertEqual(
                    conversion.duration, Double(sample.frames) / Double(sample.sampleRate), accuracy: 1e-9, sample.path)
                // afinfo describes the converted file, and the iPhone has no afinfo: it is checked there by
                // its length and by playing (below), and the Mac's host also by what afinfo says of it.
                #if os(macOS)
                let convertedRead = try await AudioFileInfo.read(conversion.converted)
                let converted = try XCTUnwrap(convertedRead, sample.path)
                XCTAssertEqual(converted.formatID, "alac", sample.path)
                // The smallest depth that holds the samples: 16, 24, or 32 (24 for 17 to 20 bits).
                XCTAssertEqual(
                    converted.bitsPerSample,
                    ImportAudioConverter.appleLosslessBitDepth(forBitsPerSample: sample.isFloat ? nil : sample.bits),
                    sample.path)
                XCTAssertEqual(converted.sampleRate, Double(sample.sampleRate), sample.path)
                XCTAssertEqual(converted.channels, min(sample.channels, 2), sample.path)
                #endif
                // The probe's length, which the iPhone has instead of afinfo's, is the source's to within a
                // millisecond (Apple Lossless adds no priming), so a cut-short .m4a fails there too.
                switch await AudioMediaProbe.duration(of: conversion.converted) {
                case .failure: XCTFail("\(sample.path) does not play")
                case let .success(seconds):
                    XCTAssertEqual(seconds, Double(sample.frames) / Double(sample.sampleRate), accuracy: 0.001, sample.path)
                }
                // The samples are read back with Apple's audio file reader, which a unit test of the iPhone
                // may not name (the iPhone's tests name no audio framework), so only the Mac's host does.
                #if os(macOS)
                let written = try samplesOfConvertedFile(at: conversion.converted)
                let expected = try samplesToBeWritten(of: sample.path)
                XCTAssertEqual(written.count, expected.count, sample.path)
                XCTAssertTrue(written == expected, "\(sample.path): the .m4a's samples differ from the source's")
                // Whole numbers of one or two channels are written as they
                // are, so the .m4a is compared with the source recording's
                // own digest too, which no reader of TextMouth's had a hand
                // in: a reader and the converter cannot be wrong together
                // (as they were of 20 bits in 24, each sample 16 times too large).
                if let digest = sample.digest, !sample.isFloat, sample.channels <= 2 {
                    let narrowed = written.map { $0 >> Int32(32 - sample.bits) }
                    XCTAssertEqual(sha256(of: waveBytes(of: narrowed, bits: sample.bits)), digest, sample.path)
                }
                #endif
                // The source is left as it was.
                XCTAssertEqual([UInt8](try Data(contentsOf: source)), try ownAudioSampleBytes(sample.path), sample.path)
            }
        }
    }

    /// A lossy WavPack file, and a hybrid one without its correction file,
    /// become AAC that plays and lasts as long.
    func testALossyFileConvertsToAAC() async throws {
        for (path, alone) in [("wv/lossy16.wv", false), ("wv/hybrid16.wv", true)] {
            let source = try copySample(path, alone: alone)
            let conversion = try await ImportAudioConverter.convert(source)
            XCTAssertEqual(conversion.duration, 0.25, accuracy: ImportAudioConverter.allowedLengthError(for: 0.25), path)
            XCTAssertNotNil(conversion.bitRate, "\(path) is lossy, so it is encoded at a bit rate")
            // afinfo describes the converted file, and the iPhone has no afinfo (the conversion's own check, and
            // playing, below, hold there).
            #if os(macOS)
            let convertedRead = try await AudioFileInfo.read(conversion.converted)
            let converted = try XCTUnwrap(convertedRead, path)
            XCTAssertEqual(converted.formatID, "aac ", path)
            XCTAssertEqual(converted.channels, 2, path)
            XCTAssertEqual(converted.duration, 0.25, accuracy: ImportAudioConverter.allowedLengthError(for: 0.25), path)
            #endif
            if case .failure = await AudioMediaProbe.duration(of: conversion.converted) { XCTFail("\(path) does not play") }
        }
    }

    /// The file's tags reach the .m4a, where the import reads its title and
    /// author from: a True Audio file's and a WavPack file's.
    func testTheTagsReachTheConvertedFile() async throws {
        for path in ["tta/tagged16.tta", "wv/tagged16.wv", "ape/tagged16.ape"] {
            let source = try copySample(path)
            let conversion = try await ImportAudioConverter.convert(source)
            let metadata = await AudioPlaybackService.extractFullMetadata(from: conversion.converted)
            XCTAssertEqual(metadata.title, "Ferry Timetables", path)
            XCTAssertEqual(metadata.artist, "Odalys Brennecke", path)
            XCTAssertEqual(metadata.album, "Harbour Notices", path)
        }
    }

    /// The cue sheet in a file's tag gives the source its chapters, each
    /// track that begins before the audio ends, and a conversion that
    /// keeps chapters writes them into the .m4a; a file without a sheet has
    /// none.
    func testACueSheetInTheTagBecomesChapters() async throws {
        var tags = OwnAudioTags()
        XCTAssertEqual(OwnAudioConverter.chapters(in: tags, lasting: 60), [])
        tags.artist = "Odalys Brennecke"
        tags.cueSheet = """
            PERFORMER "Odalys Brennecke"
            FILE "talk.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Morning Crossings"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                PERFORMER "Ilse Varga"
                INDEX 01 00:30:00
              TRACK 03 AUDIO
                TITLE "After The End"
                INDEX 01 02:00:00
            """
        let placed = OwnAudioConverter.chapters(in: tags, lasting: 60)
        XCTAssertEqual(placed.map(\.start), [0, 30])
        XCTAssertEqual(placed.first?.title, "Morning Crossings")
        XCTAssertEqual(placed.last?.title.contains("Ilse Varga"), true)

        let source = try copySample("wv/tagged16.wv")
        let described = try OwnAudioConverter.sourceInfo(of: source)
        XCTAssertEqual(described?.chapters.map(\.title), ["Morning Crossings", "Evening Crossings"])
        let conversion = try await ImportAudioConverter.convert(source, keepingChapters: true)
        let kept = await AudioPlaybackService.extractChapters(from: conversion.converted)
        XCTAssertEqual(kept.map(\.title), ["Morning Crossings", "Evening Crossings"])
        XCTAssertEqual(kept.first?.startTime ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(kept.last?.startTime ?? -1, 0.2, accuracy: 0.01)
        XCTAssertEqual(try OwnAudioConverter.sourceInfo(of: try copySample("wv/stereo16.wv"))?.chapters, [])
    }

    /// Only the fields a file has become metadata items.
    func testOnlyTheFieldsThereBecomeMetadata() {
        XCTAssertTrue(OwnAudioConverter.metadataItems(for: OwnAudioTags()).isEmpty)
        let items = OwnAudioConverter.metadataItems(for: OwnAudioTags(title: "A", genre: "Speech", date: "2026"))
        XCTAssertEqual(items.compactMap(\.identifier), [.commonIdentifierTitle, .commonIdentifierType, .commonIdentifierCreationDate])
    }

    /// Six channels that name no layout are refused as every such source
    /// is, and nothing is left beside the source: neither True Audio nor
    /// Monkey's Audio says which channel is which.
    func testChannelsWithoutALayoutAreRefused() async throws {
        for (path, name) in [("tta/six16.tta", "six16.tta"), ("ape/six16-normal.ape", "six16-normal.ape")] {
            let source = try copySample(path)
            let failure = await conversionFailure(of: source)
            XCTAssertEqual(failure, .unlabelledChannels(fileName: name, channels: 6), path)
            XCTAssertEqual(namesOfFiles(in: source.deletingLastPathComponent()), [name], path)
        }
    }

    /// A Monkey's Audio file older than version 3.99 fails the conversion
    /// in words that say why.
    func testAnOldMonkeysAudioFileIsRefusedWithItsReason() async throws {
        // Bytes 4 and 5 are the version times 1,000: 3,970 here.
        var bytes = try ownAudioSampleBytes("ape/mono16-fast.ape")
        bytes.replaceSubrange(4..<6, with: [0x82, 0x0F])
        let old = try writeFile(bytes, named: "Old.ape")
        let failure = await conversionFailure(of: old)
        XCTAssertEqual(failure, .notRead(fileName: "Old.ape", problem: .unsupported(reason: OwnAudioWording.monkeysAudioOld)))
        XCTAssertEqual(
            failure?.errorDescription,
            "TextMouth can't read the audio file Old.ape because it was made by a Monkey's Audio older than "
                + "version 3.99, from before 2004."
        )
    }

    /// A file its reader refuses fails the conversion with the reader's
    /// reason, in a sentence that names the file; a damaged or cut file
    /// says so. Nothing is left beside the source.
    func testAFileTheReaderRefusesSaysWhy() async throws {
        // Byte 4 is the format's low byte; `ownAudioSampleBytes` promises 64 bytes.
        var locked = try ownAudioSampleBytes("tta/mono16.tta")
        locked.replaceSubrange(4..<5, with: [2])
        let crc = OwnAudioCRC32.checksum(locked, in: 0..<18)
        for index in 0..<4 { locked[18 + index] = UInt8(truncatingIfNeeded: crc >> UInt32(8 * index)) }
        let lockedFile = try writeFile(locked, named: "Locked.tta")
        let lockedFailure = await conversionFailure(of: lockedFile)
        XCTAssertEqual(lockedFailure, .notRead(fileName: "Locked.tta", problem: .unsupported(reason: OwnAudioWording.ttaPassword)))
        XCTAssertEqual(
            lockedFailure?.errorDescription,
            "TextMouth can't read the audio file Locked.tta because it is locked with a password."
        )
        let lockedRead = try await ImportAudioConverter.inspect(lockedFile)
        XCTAssertNil(lockedRead, "A refused file reads as no audio where no reason is asked for")

        var damaged = try ownAudioSampleBytes("tta/mono16.tta")
        damaged[damaged.count / 2] ^= 0x10
        let damagedFile = try writeFile(damaged, named: "Damaged.tta")
        let damagedFailure = await conversionFailure(of: damagedFile)
        XCTAssertEqual(damagedFailure, .notRead(fileName: "Damaged.tta", problem: .damaged))
        XCTAssertEqual(
            damagedFailure?.errorDescription,
            "The audio file Damaged.tta is damaged, so it could not be converted."
        )
        XCTAssertEqual(namesOfFiles(in: damagedFile.deletingLastPathComponent()), ["Damaged.tta"])

        let whole = try ownAudioSampleBytes("tta/mono16.tta")
        let cutFile = try writeFile(Array(whole.prefix(whole.count / 2)), named: "Cut.tta")
        let cutFailure = await conversionFailure(of: cutFile)
        XCTAssertEqual(cutFailure, .notRead(fileName: "Cut.tta", problem: .truncated))
        XCTAssertEqual(
            cutFailure?.errorDescription,
            "The audio file Cut.tta ends before its audio does, so it could not be converted."
        )
        XCTAssertEqual(
            ImportAudioConverter.Failure.notWritten(fileName: "a.tta", reason: "SomeErrorDomain -11800").errorDescription,
            "The audio converted from a.tta could not be written (SomeErrorDomain -11800)."
        )
        XCTAssertEqual(
            OwnAudioWording.sentence(for: .notThisFormat, fileName: "a.tta"),
            "The audio file a.tta is not the kind of file its name says."
        )
    }

    /// A .wv file from before WavPack 4 starts as a WAVE file does: it is
    /// refused with its reason, and never taken for a WAVE file.
    func testAnOldWavPackFileIsRefusedWithItsReason() async throws {
        let wave: [UInt8] = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVEfmt ".utf8) + [UInt8](repeating: 0, count: 64)
        let old = try writeFile(wave, named: "Old.wv")
        let failure = await conversionFailure(of: old)
        XCTAssertEqual(failure, .notRead(fileName: "Old.wv", problem: .unsupported(reason: OwnAudioWording.wavPackOld)))
        XCTAssertEqual(
            failure?.errorDescription,
            "TextMouth can't read the audio file Old.wv because it was made by a WavPack older than version 4, from before 2004."
        )
    }

    /// A hybrid file whose correction file is damaged fails the conversion
    /// rather than passing lossy audio off as lossless, and the sentence
    /// names the correction file, which is the one to replace.
    func testADamagedCorrectionFileFailsTheConversion() async throws {
        let source = try copySample("wv/hybrid16.wv")
        let companion = try XCTUnwrap(OwnAudioConverter.companion(of: source))
        var bytes = [UInt8](try Data(contentsOf: companion))
        bytes[bytes.count / 2] ^= 0x20
        try Data(bytes).write(to: companion)
        let failure = await conversionFailure(of: source)
        XCTAssertEqual(failure, .notRead(fileName: "hybrid16.wv", problem: .companionDamaged))
        XCTAssertEqual(
            failure?.errorDescription,
            "The correction file hybrid16.wvc is damaged or belongs to another recording, "
                + "so hybrid16.wv could not be converted.")
        XCTAssertEqual(namesOfFiles(in: source.deletingLastPathComponent()), ["hybrid16.wv", "hybrid16.wvc"])
    }

    /// A header that promises more than a year of audio is refused as
    /// damage before any of it is decoded.
    func testALengthNoRecordingHasIsRefused() async throws {
        // Byte 11 of a WavPack file is the top byte of its 40-bit length in
        // frames: 255 there makes this file of 22,050 Hz last 575 days. The
        // file is ffmpeg's, whose blocks carry no checksum of their bytes, so
        // the header still reads; without the cap it would decode until the
        // file ended, and be refused as cut short instead.
        var bytes = try ownAudioSampleBytes("wv/ffmpeg-mono16.wv")
        bytes.replaceSubrange(11..<12, with: [0xFF])
        let file = try writeFile(bytes, named: "Endless.wv")
        let failure = await conversionFailure(of: file)
        XCTAssertEqual(failure, .notRead(fileName: "Endless.wv", problem: .damaged))
        XCTAssertGreaterThan(
            try WavPackDecoder(OwnAudioBytes(bytes)).stream.duration, AudioFileInfo.maximumPlausibleDuration)
        XCTAssertEqual(namesOfFiles(in: file.deletingLastPathComponent()), ["Endless.wv"])
    }

    /// A conversion stops when its task is cancelled, and leaves nothing.
    func testACancelledConversionLeavesNothing() async throws {
        let source = try copySample("tta/tones.tta")
        let task = Task { try await ImportAudioConverter.convert(source) }
        task.cancel()
        do {
            _ = try await task.value
            // A conversion this short may finish before it sees the cancellation.
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(namesOfFiles(in: source.deletingLastPathComponent()), ["tones.tta"])
        }
    }

    // MARK: - The Sources Afterwards

    /// Removing a converted file's source removes its correction file too;
    /// keeping it keeps both, side by side, in the kept originals.
    func testACorrectionFileGoesWhereItsFileGoes() async throws {
        let removed = try copySample("wv/hybridmono16.wv")
        let removedConversion = try await ImportAudioConverter.convert(removed)
        try ImportAudioConverter.removeSources(of: [removedConversion])
        XCTAssertEqual(namesOfFiles(in: removed.deletingLastPathComponent()), ["hybridmono16.m4a"])

        let package = folder.appendingPathComponent("Package")
        let audio = package.appendingPathComponent("audio/Disc 1")
        let kept = try copySample("wv/hybridmono16.wv", into: audio)
        let keptConversion = try await ImportAudioConverter.convert(kept)
        try ImportAudioConverter.keepSources(of: [keptConversion], from: package.appendingPathComponent("audio"), inPackage: package)
        XCTAssertEqual(namesOfFiles(in: audio), ["hybridmono16.m4a"])
        let originals = ImportAudioConverter.keptOriginals(inPackage: package)
        XCTAssertEqual(originals.map(\.lastPathComponent), ["hybridmono16.wv", "hybridmono16.wvc"])
        XCTAssertEqual(Set(originals.map { $0.deletingLastPathComponent().lastPathComponent }), ["Disc 1"])
        XCTAssertEqual(
            Set(originals.map { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }),
            [ImportAudioConverter.keptOriginalsFolderName])
    }

    // MARK: - Importing

    /// A single True Audio file imports as an .m4a file, which is the
    /// book's file, titled and credited from its tags; no .tta is left in
    /// the package, and the file imported from is untouched.
    func testASingleFileImportsAsAnM4AFile() throws {
        let source = try copySample("tta/tagged16.tta")
        let sourceBytes = try Data(contentsOf: source)

        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(audio.lastPathComponent, "tagged16.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(namesOfFiles(in: audio.deletingLastPathComponent()).filter { $0.hasSuffix(".tta") }, [])
        XCTAssertEqual(imported.book.title, "Ferry Timetables")
        XCTAssertEqual(imported.book.author, "Odalys Brennecke")
        XCTAssertEqual(imported.book.audioAlbum, "Harbour Notices")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

    /// A hybrid WavPack file chosen with its correction file beside it
    /// imports as Apple Lossless that holds the source's samples; neither
    /// file is left in the package, and both originals are untouched.
    func testAHybridFileImportsWithItsCorrectionFile() throws {
        let source = try copySample("wv/hybrid16.wv")
        let before = namesOfFiles(in: source.deletingLastPathComponent())

        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(audio.lastPathComponent, "hybrid16.m4a")
        // The import waits on its own thread for its conversions, so this test is not an async one.
        // Read back with Apple's audio file reader, which only the Mac's host names (as above).
        #if os(macOS)
        XCTAssertTrue(try isAppleLossless(audio))
        XCTAssertTrue(try samplesOfConvertedFile(at: audio) == (try samplesToBeWritten(of: "wv/hybrid16.wv")))
        #endif
        let left = namesOfFiles(in: audio.deletingLastPathComponent())
        XCTAssertEqual(left.filter { $0.hasSuffix(".wv") || $0.hasSuffix(".wvc") }, [])
        XCTAssertEqual(namesOfFiles(in: source.deletingLastPathComponent()), before)
    }

    /// A folder of a True Audio track, an MP3, a hybrid WavPack track with
    /// its correction file, and a True Audio track imports in order, the
    /// MP3 as it is, and no correction file is left among the tracks.
    func testAFolderOfTracksImportsInOrder() throws {
        let source = folder.appendingPathComponent("Mixed")
        try copySample("tta/mono16.tta", as: "01.tta", into: source)
        let mp3 = try requireFile("format-samples/mp3-chapters/three-tones.mp3")
        try FileManager.default.copyItem(at: mp3, to: source.appendingPathComponent("02.mp3"))
        try copySample("wv/hybridmono16.wv", as: "03.wv", into: source)
        try copySample("tta/stereo16.tta", as: "04.TTA", into: source)

        let imported = try FileImportService.importAudioFolderWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio), ["01.m4a", "02.mp3", "03.m4a", "04.m4a"])
        let sourceEndings: Set<String> = ["tta", "wv", "wvc"]
        XCTAssertEqual(
            namesOfFiles(in: audio).filter { sourceEndings.contains(($0 as NSString).pathExtension.lowercased()) }, [])
        XCTAssertEqual(namesOfFiles(in: source), ["01.tta", "02.mp3", "03.wv", "03.wvc", "04.TTA"])
    }

    /// A damaged True Audio file fails the import at Converting its audio,
    /// in the reader's words, and leaves nothing in the library folder.
    func testADamagedFileFailsTheImportAtItsStep() throws {
        var damaged = try ownAudioSampleBytes("tta/mono16.tta")
        damaged[damaged.count / 2] ^= 0x10
        let source = try writeFile(damaged, named: "Noise.tta")
        let libraryBefore = namesOfFiles(in: TextMouthPaths.libraryDir)

        do {
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("A damaged file must not import")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step.activity, "Converting its audio")
            XCTAssertEqual(
                failure.underlying as? ImportAudioConverter.Failure,
                .notRead(fileName: "Noise.tta", problem: .damaged)
            )
            XCTAssertEqual(
                failure.errorDescription,
                "Could not import “Noise.tta”. Converting its audio failed: "
                    + "The audio file Noise.tta is damaged, so it could not be converted."
            )
        }
        XCTAssertEqual(namesOfFiles(in: TextMouthPaths.libraryDir), libraryBefore)
    }
}
