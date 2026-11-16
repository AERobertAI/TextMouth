import XCTest
import UniformTypeIdentifiers
@testable import TextMouth

/// The containers only ffmpeg reads, told from their first bytes (FMT31,
/// FMT32), and the protection check of Windows Media files: pure Swift on
/// the repository's samples and on bytes made here, so every test runs on
/// GitHub's runners, which have no ffmpeg.
final class FFmpegImportSnifferTests: XCTestCase {
    // MARK: - The Samples

    /// Each sample is told as the container it is, whatever it holds: WMA 1
    /// and 2 and a WMV are ASF; WebM and Matroska, audio or video, are
    /// Matroska; Speex in Ogg is Ogg Speex. Every mismatch is reported.
    func testEachSampleIsToldAsItsContainer() throws {
        let expected: [(String, FFmpegContainer)] = [
            ("wma/tones.wma", .asf),
            ("wma/tones-wma1.wma", .asf),
            ("wma/three-tones-chapters.wma", .asf),
            ("wmv/tones.wmv", .asf),
            ("webm/tones-opus.webm", .matroska),
            ("webm/tones-vorbis.weba", .matroska),
            ("mka/tones-2tracks.mka", .matroska),
            ("mka/tones-5.1-ac3.mka", .matroska),
            ("mkv/three-tones-flac.mkv", .matroska),
            ("avi/tones-mp3.avi", .avi),
            ("flv/tones-aac.flv", .flv),
            ("rm/tones.ra", .realMedia),
            ("spx/tones.spx", .oggSpeex),
        ]
        var mismatches: [String] = []
        for (sample, container) in expected {
            let found = FFmpegContainer.of(fileAt: try formatSampleURL(sample))
            if found != container { mismatches.append("\(sample): \(String(describing: found)), not \(container)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Ogg of the codecs afconvert reads is plain Ogg, and the formats
    /// TextMouth plays as they are, or that macOS converts, are none of
    /// these containers: neither goes to ffmpeg unless its name says so.
    func testOtherAudioIsNoneOfTheseContainers() throws {
        for sample in ["audio/ogg-vorbis-tone.ogg", "audio/ogg-opus-tone.opus", "audio/ogg-flac-tone.oga"] {
            XCTAssertEqual(FFmpegContainer.of(fileAt: try requireFile(sample)), .ogg, sample)
            XCTAssertFalse(FFmpegAudioConverter.converts(try requireFile(sample)), sample)
        }
        for sample in ["mp3-chapters/three-tones.mp3", "m4b-chapters/three-tones.m4b", "flac-chapters/three-tones.flac",
                       "wav-variants/extensible-24bit.wav", "ac3/tones.ac3", "caf/tones-pcm.caf"] {
            XCTAssertNil(FFmpegContainer.of(fileAt: try formatSampleURL(sample)), sample)
        }
    }

    /// A file that is missing, empty, or too short to hold a signature is no
    /// container, and nothing is read past the bytes there are; a short Ogg
    /// page is Ogg, and holds no Speex.
    func testMissingEmptyAndShortFilesAreNoContainer() throws {
        let folder = try makeSandboxDirectory("FFmpegSniffShort")
        XCTAssertNil(FFmpegContainer.of(fileAt: folder.appendingPathComponent("missing.wma")))
        let empty = folder.appendingPathComponent("empty.wma")
        try Data().write(to: empty)
        XCTAssertNil(FFmpegContainer.of(fileAt: empty))
        let prefixes: [[UInt8]] = [[0x30, 0x26, 0xB2], [0x1A, 0x45], Array("FLV".utf8), Array("RIFF".utf8), Array("MP+".utf8)]
        for prefix in prefixes {
            XCTAssertNil(FFmpegContainer.of(prefix), "\(prefix)")
        }
        XCTAssertEqual(FFmpegContainer.of(Array("OggS".utf8) + [0, 2]), .ogg)
    }

    // MARK: - Signatures Made Here

    /// The signatures without a sample of their own: Musepack's two stream
    /// versions (7 in the low four bits of "MP+"'s fourth byte, 7.1 too,
    /// and "MPCK"), an old RealAudio file, and an AVI's RIFF form; a
    /// Musepack header of another version is not taken.
    func testSignaturesWithoutSamples() {
        XCTAssertEqual(FFmpegContainer.of(Array("MP+".utf8) + [0x07, 0, 0]), .musepack7)
        XCTAssertEqual(FFmpegContainer.of(Array("MP+".utf8) + [0x17, 0, 0]), .musepack7)
        XCTAssertNil(FFmpegContainer.of(Array("MP+".utf8) + [0x08, 0, 0]))
        XCTAssertEqual(FFmpegContainer.of(Array("MPCK".utf8) + [0x53, 0x48]), .musepack8)
        XCTAssertEqual(FFmpegContainer.of(Array(".ra".utf8) + [0xFD, 0, 4]), .realMedia)
        XCTAssertEqual(FFmpegContainer.of(joinedBytes(Array("RIFF".utf8), [1, 2, 3, 4], Array("AVI LIST".utf8))), .avi)
        XCTAssertNil(FFmpegContainer.of(joinedBytes(Array("RIFF".utf8), [1, 2, 3, 4], Array("WAVEfmt ".utf8))))
    }

    /// Each container names the demuxer ffmpeg knows it by.
    func testEachContainerNamesItsDemuxer() {
        let demuxers = Dictionary(uniqueKeysWithValues: FFmpegContainer.allCases.map { ($0, $0.demuxer) })
        XCTAssertEqual(demuxers, [
            .asf: "asf", .matroska: "matroska", .flv: "flv", .avi: "avi", .realMedia: "rm",
            .musepack7: "mpc", .musepack8: "mpc8", .oggSpeex: "ogg", .ogg: "ogg",
        ])
    }

    /// An Ogg page's first packet follows its segment table, so a Speex
    /// header is found after a table of any length; a page with no segments,
    /// or whose packet ends before its eight bytes, holds no Speex header.
    func testSpeexIsFoundAfterTheSegmentTable() {
        /// An Ogg page header with `segments` lacing values, then `packet`.
        func page(segments: Int, packet: [UInt8]) -> [UInt8] {
            joinedBytes(
                Array("OggS".utf8), [0, 2], [UInt8](repeating: 0, count: 20), [UInt8(segments)],
                [UInt8](repeating: 0xFF, count: segments), packet
            )
        }
        let speex = Array("Speex   1.2".utf8)
        XCTAssertTrue(FFmpegContainer.isOggSpeex(page(segments: 1, packet: speex)))
        XCTAssertTrue(FFmpegContainer.isOggSpeex(page(segments: 255, packet: speex)))
        XCTAssertFalse(FFmpegContainer.isOggSpeex(page(segments: 0, packet: speex)))
        XCTAssertFalse(FFmpegContainer.isOggSpeex(page(segments: 1, packet: Array("Speex ".utf8))))
        XCTAssertFalse(FFmpegContainer.isOggSpeex(page(segments: 1, packet: Array("\u{01}vorbis".utf8))))
        XCTAssertEqual(FFmpegContainer.of(page(segments: 1, packet: Array("OpusHead".utf8))), .ogg)
    }

    /// A Skeleton track's page may begin the file before the Speex stream's:
    /// the pages that begin streams are walked by their lengths, so Speex is
    /// found on the second; a file cut from a stream, whose first page begins
    /// none, holds no header to find.
    func testSpeexIsFoundAfterASkeletonPage() {
        /// An Ogg page of one packet, `packet`, beginning a stream when `begins`.
        func page(_ packet: [UInt8], begins: Bool = true) -> [UInt8] {
            let headerType: UInt8 = begins ? 2 : 0
            return joinedBytes(
                Array("OggS".utf8), [0, headerType], [UInt8](repeating: 0, count: 20), [1, UInt8(packet.count)], packet
            )
        }
        let skeleton = page(Array("fishead".utf8) + [UInt8](repeating: 0, count: 57))
        let speex = page(Array("Speex   1.2rc1".utf8) + [UInt8](repeating: 0, count: 66))
        XCTAssertTrue(FFmpegContainer.isOggSpeex(skeleton + speex))
        XCTAssertEqual(FFmpegContainer.of(skeleton + speex), .oggSpeex)
        XCTAssertFalse(FFmpegContainer.isOggSpeex(skeleton + page(Array("\u{01}vorbis".utf8) + [0, 0, 0, 0])))
        XCTAssertFalse(FFmpegContainer.isOggSpeex(page(Array("Speex   ".utf8), begins: false)))
        // A walk that runs past the bytes there are ends without a trap.
        XCTAssertFalse(FFmpegContainer.isOggSpeex(Array(skeleton.prefix(40))))
    }

    // MARK: - Which Files Go to ffmpeg

    /// A file goes to ffmpeg by its extension, in any case, or, whatever its
    /// name, when it holds Speex in Ogg; an Ogg file of another codec stays
    /// with afconvert, and TTA, WavPack, and Monkey's Audio are never taken
    /// (TextMouth reads them itself).
    func testWhichFilesGoToFFmpeg() throws {
        for ext in FFmpegAudioConverter.extensions {
            XCTAssertTrue(FFmpegAudioConverter.converts(URL(fileURLWithPath: "/nonexistent/track.\(ext)")), ext)
            XCTAssertTrue(FFmpegAudioConverter.converts(URL(fileURLWithPath: "/nonexistent/TRACK.\(ext.uppercased())")), ext)
        }
        for ext in ["tta", "wv", "ape", "mp3", "m4a", "ogg", "opus", "ac3", "flac"] {
            XCTAssertFalse(FFmpegAudioConverter.converts(URL(fileURLWithPath: "/nonexistent/track.\(ext)")), ext)
        }
        let speexNamedOgg = try copyOfFormatSample("spx/tones.spx", named: "Speech.ogg")
        XCTAssertTrue(FFmpegAudioConverter.converts(speexNamedOgg))
        XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(speexNamedOgg))
    }

    /// Which tracks of a book of several are left out (review9 finding 2):
    /// without ffmpeg, or on the iPhone, every file only ffmpeg reads; with
    /// it, only a file whose bytes are of no container it reads. MP3 and Ogg
    /// Vorbis are never left out, and ffmpeg is looked for only when a track
    /// is one of its files.
    func testWhichTracksABookOfSeveralLeavesOut() throws {
        let folder = try makeSandboxDirectory("FFmpegLeftOut")
        let avi = folder.appendingPathComponent("Trailer.avi")
        try FileManager.default.copyItem(at: try formatSampleURL("avi/tones-mp3.avi"), to: avi)
        let report = folder.appendingPathComponent("Report.spx")
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array/></plist>"#.utf8).write(to: report)
        let mp3 = try formatSampleURL("mp3-chapters/three-tones.mp3")
        let vorbis = try requireFile("audio/ogg-vorbis-tone.ogg")
        let tracks = [mp3, avi, vorbis, report]

        let missing = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { .ffmpegMissing }
        XCTAssertEqual(missing.needingFFmpeg, [avi])
        XCTAssertEqual(missing.holdingNoSound, [report])
        XCTAssertEqual(missing.located, .ffmpegMissing)
        let phone = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { nil }
        XCTAssertEqual(phone.all, [avi, report])
        XCTAssertNil(phone.located)
        let installed = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { .found(self.standInPrograms) }
        XCTAssertEqual(installed.all, [report])
        let none = FFmpegAudioConverter.tracksToLeaveOut(of: [mp3, vorbis]) {
            XCTFail("ffmpeg is looked for only when a track is one of its files")
            return nil
        }
        XCTAssertEqual(none, FFmpegAudioConverter.TracksLeftOut())
    }

    /// Every extension ffmpeg converts is an audiobook extension that the
    /// import converts and no reader ever decodes in the app, and none is a
    /// package track or a feed's audio: a package holds the .m4a made of
    /// each, and a feed fetches none of them.
    func testEveryFFmpegExtensionIsConvertedAndNeverDecodedInTheApp() {
        for ext in FFmpegAudioConverter.extensions {
            let url = URL(fileURLWithPath: "/nonexistent/track.\(ext)")
            XCTAssertEqual(BookFormat.detect(from: url), .audio, ext)
            XCTAssertTrue(ImportAudioConverter.isConvertedAtImport(url), ext)
            XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(url), ext)
            XCTAssertNil(AudioPlaybackService.metadataAsset(for: url), ext)
            XCTAssertTrue(ArchiveEntryLimits.isAudio("Disc/track.\(ext)"), ext)
            XCTAssertFalse(BookFormat.packageTrackExtensions.contains(ext), ext)
            XCTAssertFalse(FeedMediaKind.audioExtensions.contains(ext), ext)
        }
        XCTAssertTrue(FFmpegAudioConverter.extensions.isDisjoint(with: ["tta", "wv", "ape"]))
    }

    /// Finder offers TextMouth for every extension ffmpeg converts, as one
    /// document type, a Viewer at rank Alternate (never the default app for
    /// a video), naming the system's types and TextMouth's own for those
    /// macOS does not declare; .spx, the System Profiler's, by extension only.
    func testFinderOffersTheFFmpegFormatsAsOneAlternateViewer() throws {
        let type = try XCTUnwrap(documentType(listing: "wma"))
        XCTAssertEqual(type["CFBundleTypeName"] as? String, "Audio and Video Converted with ffmpeg")
        XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(Set(type["CFBundleTypeExtensions"] as? [String] ?? []), FFmpegAudioConverter.extensions)
        XCTAssertEqual(type["LSItemContentTypes"] as? [String], [
            "com.microsoft.windows-media-wma", "com.microsoft.advanced-systems-format", "com.microsoft.windows-media-wmv",
            "com.textmouth.musepack", "com.textmouth.matroska-audio", "com.textmouth.matroska-video", "org.webmproject.webm",
            "com.textmouth.webm-audio", "public.avi", "com.adobe.flash.video", "com.real.realaudio", "com.real.realmedia",
            "com.real.realmedia-vbr",
        ])
        XCTAssertFalse((type["LSItemContentTypes"] as? [String] ?? []).contains("com.apple.systemprofiler.document"))
    }

    /// The Open panel offers every extension ffmpeg converts, by the type
    /// the extension has in this process (the system's, TextMouth's own
    /// declaration, or one made for it).
    func testTheOpenPanelOffersEveryFFmpegExtension() {
        let offered = Set(FileImportService.supportedTypes)
        let missing = FFmpegAudioConverter.extensions.sorted().filter { ext in
            guard let type = UTType(filenameExtension: ext) else { return true }
            return !offered.contains(type)
        }
        XCTAssertEqual(missing, [])
    }

    /// A file that holds TTA, WavPack, or Monkey's Audio is never ffmpeg's,
    /// whatever its name, after an ID3v2 tag too: TextMouth's own readers
    /// take such a file by its content. A WMA file is still ffmpeg's.
    func testTheFormatsTextMouthReadsItselfAreNeverFFmpegs() throws {
        for (sample, name) in [("tta/tones.tta", "Disguised.wma"), ("wv/tones.wv", "Disguised.mka")] {
            let copy = try copyOfFormatSample(sample, named: name)
            XCTAssertTrue(FFmpegContainer.holdsOwnReaderFormat(fileAt: copy), name)
            XCTAssertFalse(FFmpegAudioConverter.converts(copy), name)
        }
        let folder = try makeSandboxDirectory("FFmpegOwnReaders")
        let ape = folder.appendingPathComponent("Disc.webm")
        try Data(Array("MAC ".utf8) + [0x96, 0x0F, 0, 0]).write(to: ape)
        XCTAssertFalse(FFmpegAudioConverter.converts(ape))
        // Monkey's Audio of floating-point samples.
        let floats = folder.appendingPathComponent("Floats.mka")
        try Data(Array("MACF".utf8) + [0x96, 0x0F, 0, 0]).write(to: floats)
        XCTAssertFalse(FFmpegAudioConverter.converts(floats))
        // An ID3v2 tag of 20 bytes (version 4, no flags) before the signature.
        let tagged = folder.appendingPathComponent("Tagged.wma")
        try Data(joinedBytes(Array("ID3".utf8), [4, 0, 0, 0, 0, 0, 20], [UInt8](repeating: 0, count: 20), Array("TTA1".utf8), [1, 0]))
            .write(to: tagged)
        XCTAssertTrue(FFmpegContainer.holdsOwnReaderFormat(fileAt: tagged))
        XCTAssertFalse(FFmpegAudioConverter.converts(tagged))
        XCTAssertTrue(FFmpegAudioConverter.converts(try copyOfFormatSample("wma/tones.wma")))
        XCTAssertFalse(FFmpegContainer.holdsOwnReaderFormat(fileAt: folder.appendingPathComponent("missing.wma")))
    }

    // MARK: - Copy Protection

    /// The Header object's identifier is the first 16 bytes of every ASF
    /// file, so the byte order of `guidBytes` is the files' own.
    func testTheHeaderIdentifierIsTheSamplesFirstBytes() throws {
        let bytes = try XCTUnwrap(AudioContentSniffer.firstBytes(of: try formatSampleURL("wma/tones.wma"), upTo: 16))
        XCTAssertEqual(bytes, ASFHeader.headerObjectID)
        XCTAssertEqual(ASFHeader.headerObjectID.count, 16)
        XCTAssertEqual(ASFHeader.guidBytes("not a GUID"), [])
        for identifier in ASFHeader.protectionObjectIDs {
            XCTAssertEqual(identifier.count, 16)
        }
    }

    /// None of the repository's Windows Media samples is protected.
    func testTheSamplesAreNotCopyProtected() throws {
        for sample in ["wma/tones.wma", "wma/tones-wma1.wma", "wma/three-tones-chapters.wma", "wmv/tones.wmv"] {
            XCTAssertFalse(ASFHeader.isCopyProtected(fileAt: try formatSampleURL(sample)), sample)
        }
        XCTAssertFalse(ASFHeader.isCopyProtected(fileAt: try formatSampleURL("mka/tones-2tracks.mka")))
    }

    /// Each of the four protection objects marks a file protected, at the
    /// header's top level or inside its Header Extension, as a real sample's
    /// header with the object added: Content Encryption, Extended Content
    /// Encryption, Advanced Content Encryption (Windows Media DRM for Network
    /// Devices), and PlayReady's Protection System Identifier (review9
    /// finding 4).
    func testEachProtectionObjectMarksAFileProtected() throws {
        let sample = try Data(contentsOf: try formatSampleURL("wma/tones.wma"))
        // Spelled here, so a protection system left out of the list fails.
        let identifiers = [
            "2211B3FB-BD23-11D2-B4B7-00A0C955FC6E", // Content Encryption: Windows Media DRM 1
            "298AE614-2622-4C17-B935-DAE07EE9289C", // Extended Content Encryption: DRM 7 and later
            "43058533-6981-49E6-9B74-AD12CB86D58C", // Advanced Content Encryption: DRM for Network Devices
            "9A04F079-9840-4286-AB92-E65BE0885F95", // Protection System Identifier: PlayReady
        ]
        XCTAssertEqual(ASFHeader.protectionObjectIDs, identifiers.map(ASFHeader.guidBytes))
        for spelled in identifiers {
            let identifier = ASFHeader.guidBytes(spelled)
            XCTAssertEqual(identifier.count, 16, spelled)
            let protected = try asfHeaderAdding(asfObject(identifier, body: [0, 0, 0, 0]), to: sample)
            XCTAssertTrue(ASFHeader.isCopyProtected(header: protected), "\(spelled) at the top level")
            let nested = try asfHeaderAdding(headerExtension(holding: asfObject(identifier, body: [])), to: sample)
            XCTAssertTrue(ASFHeader.isCopyProtected(header: nested), "\(spelled) in the extension")
        }
        XCTAssertFalse(ASFHeader.isCopyProtected(header: try asfHeaderAdding(headerExtension(holding: []), to: sample)))
    }

    /// The file check reads the header from the file: a copy of a sample with
    /// a protection object added is protected; the sample is not.
    func testTheFileCheckReadsTheHeader() throws {
        let file = try makeSandboxDirectory("FFmpegSniffProtected").appendingPathComponent("Locked.wma")
        try copyProtectedASF(from: try formatSampleURL("wma/tones.wma")).write(to: file)
        XCTAssertTrue(ASFHeader.isCopyProtected(fileAt: file))
        XCTAssertEqual(FFmpegContainer.of(fileAt: file), .asf)
    }

    /// A damaged header is judged by the objects before the damage: an
    /// object whose size is less than its own 24 bytes, or runs past its
    /// header, ends the walk, so a protection object after it goes unseen;
    /// before it, it is seen. Nothing traps, whatever the sizes say.
    func testADamagedHeaderEndsTheWalk() throws {
        let protection = asfObject(try XCTUnwrap(ASFHeader.protectionObjectIDs.first), body: [])
        let tooSmall = Array(repeating: UInt8(0xAB), count: 16) + asfLittleEndian(UInt64(8), count: 8)
        let tooLarge = Array(repeating: UInt8(0xCD), count: 16) + asfLittleEndian(UInt64.max, count: 8)
        for broken in [tooSmall, tooLarge] {
            XCTAssertFalse(ASFHeader.isCopyProtected(header: asfHeader(objects: [broken, protection])))
            XCTAssertTrue(ASFHeader.isCopyProtected(header: asfHeader(objects: [protection, broken])))
        }
        // A header that claims more bytes than there are is walked as far as they go.
        var short = asfHeader(objects: [protection])
        short.replaceSubrange(16..<24, with: asfLittleEndian(UInt64(1) << 40, count: 8))
        XCTAssertTrue(ASFHeader.isCopyProtected(header: short))
        // Too few bytes for a Header object at all, or another file's.
        XCTAssertFalse(ASFHeader.isCopyProtected(header: Array(ASFHeader.headerObjectID.prefix(20))))
        XCTAssertFalse(ASFHeader.isCopyProtected(header: Array(repeating: 0, count: 64)))
    }

    // MARK: - Making ASF Headers

    /// A Header object holding `objects`, with its size and count right.
    private func asfHeader(objects: [[UInt8]]) -> [UInt8] {
        let body = objects.flatMap { $0 }
        return joinedBytes(
            ASFHeader.headerObjectID, asfLittleEndian(UInt64(30 + body.count), count: 8),
            asfLittleEndian(UInt64(objects.count), count: 4), [1, 2], body
        )
    }

    /// The Header object of the ASF file `file`, with `object` added: the
    /// header alone, which is all the protection check reads.
    private func asfHeaderAdding(_ object: [UInt8], to file: Data) throws -> [UInt8] {
        try asfFile([UInt8](file), adding: object).header
    }
}

// MARK: - ASF Files Made Here

extension XCTestCase {
    /// `value` as `count` little-endian bytes, as ASF writes its numbers.
    func asfLittleEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// An ASF object: `identifier`, its size (24 bytes and the body's), and `body`.
    func asfObject(_ identifier: [UInt8], body: [UInt8]) -> [UInt8] {
        identifier + asfLittleEndian(UInt64(24 + body.count), count: 8) + body
    }

    /// A Header Extension object holding `objects`: its reserved identifier
    /// (16 bytes), reserved number (2), and data size (4), then the objects.
    func headerExtension(holding objects: [UInt8]) -> [UInt8] {
        let fields = joinedBytes([UInt8](repeating: 0x11, count: 16), [6, 0], asfLittleEndian(UInt64(objects.count), count: 4))
        return asfObject(ASFHeader.headerExtensionID, body: fields + objects)
    }

    /// `parts` joined in order: one array of bytes, made without a chain of
    /// `+`, whose many literals the type checker can take too long to settle.
    func joinedBytes(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }

    /// The ASF file `bytes` with `object` added at the end of its Header
    /// object, the header's size and count raised to match, and the packets
    /// after it as they were: the new header, and the whole new file.
    func asfFile(_ bytes: [UInt8], adding object: [UInt8]) throws -> (header: [UInt8], file: Data) {
        let noHeader = TestError.assertionFailed("No ASF header in \(bytes.count) bytes")
        guard bytes.count > 30 else { throw noHeader }
        let size = bytes[16..<24].reversed().reduce(0) { $0 << 8 | Int($1) }
        let count = bytes[24..<28].reversed().reduce(0) { $0 << 8 | Int($1) }
        guard size > 30, size <= bytes.count else { throw noHeader }
        var header = Array(bytes[0..<size])
        header.replaceSubrange(16..<24, with: asfLittleEndian(UInt64(size + object.count), count: 8))
        header.replaceSubrange(24..<28, with: asfLittleEndian(UInt64(count + 1), count: 4))
        return (header + object, Data(header + object + bytes[size...]))
    }

    /// The bytes of the ASF file at `url` made copy-protected, as a file of
    /// Windows Media DRM version 7 is: an Extended Content Encryption object
    /// added to its header (`asfFile(_:adding:)`). The ffmpeg import's tests
    /// refuse such a file (FMT31).
    func copyProtectedASF(from url: URL) throws -> Data {
        // The second identifier is Extended Content Encryption's.
        let extended = try XCTUnwrap(ASFHeader.protectionObjectIDs.dropFirst().first, "No Extended Content Encryption identifier")
        let object = asfObject(extended, body: [0, 0, 0, 0])
        return try asfFile([UInt8](try Data(contentsOf: url)), adding: object).file
    }
}
