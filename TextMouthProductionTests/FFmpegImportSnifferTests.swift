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
            ("mka/tones-aac.mka", .matroska),
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
    /// with the Mac app's helper missing, every file only FFmpeg reads; with
    /// it, or on the iPhone, whose session is in the app (FMT54), only a file
    /// whose bytes are of no container it reads. MP3 and Ogg Vorbis are never
    /// left out, and the session is looked for only when a track is one of
    /// its files.
    func testWhichTracksABookOfSeveralLeavesOut() throws {
        let folder = try makeSandboxDirectory("FFmpegLeftOut")
        let avi = folder.appendingPathComponent("Trailer.avi")
        try FileManager.default.copyItem(at: try formatSampleURL("avi/tones-mp3.avi"), to: avi)
        let report = folder.appendingPathComponent("Report.spx")
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array/></plist>"#.utf8).write(to: report)
        let mp3 = try formatSampleURL("mp3-chapters/three-tones.mp3")
        let vorbis = try requireFile("audio/ogg-vorbis-tone.ogg")
        let tracks = [mp3, avi, vorbis, report]

        let missing = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { .missing }
        XCTAssertEqual(missing.needingConverter, [avi])
        XCTAssertEqual(missing.holdingNoSound, [report])
        XCTAssertEqual(missing.located, .missing)
        let inTheApp = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { .inProcess }
        XCTAssertEqual(inTheApp.all, [report])
        XCTAssertEqual(inTheApp.located, .inProcess)
        // The app's own: the Mac's helper, or the iPhone's session in the app.
        let bundled = FFmpegAudioConverter.tracksToLeaveOut(of: tracks) { FFmpegAudioConverter.locateBundled() }
        XCTAssertEqual(bundled.all, [report])
        let none = FFmpegAudioConverter.tracksToLeaveOut(of: [mp3, vorbis]) {
            XCTFail("the session is looked for only when a track is one of its files")
            return .missing
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

    /// Each extension ffmpeg converts but .spx (the System Profiler's on the
    /// Mac) has, in this process, a type its document type names, so the
    /// system offers TextMouth for such a file: on the Mac in Finder, and on
    /// the iPhone in "Open in TextMouth" (FMT54), where only the types a
    /// document type names count, never its extensions. A type of the
    /// system's that this system did not declare would be made up for the
    /// extension, and named by none.
    func testEachFFmpegExtensionHasATypeItsDocumentTypeNames() throws {
        let named = Set(try XCTUnwrap(documentType(listing: "wma"))["LSItemContentTypes"] as? [String] ?? [])
        var unnamed: [String] = []
        for ext in FFmpegAudioConverter.extensions.subtracting(["spx"]).sorted() {
            let type = UTType(filenameExtension: ext)
            if !named.contains(type?.identifier ?? "") {
                unnamed.append("\(ext): \(type?.identifier ?? "none") (declared: \(type?.isDeclared ?? false))")
            }
        }
        XCTAssertEqual(unnamed, [])
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
            XCTAssertNotNil(OwnAudioConverter.format(of: copy), name)
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
        XCTAssertEqual(OwnAudioConverter.format(of: tagged), .trueAudio)
        XCTAssertFalse(FFmpegAudioConverter.converts(tagged))
        XCTAssertTrue(FFmpegAudioConverter.converts(try copyOfFormatSample("wma/tones.wma")))
        XCTAssertNil(OwnAudioConverter.format(of: folder.appendingPathComponent("missing.wma")))
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

    // MARK: - Matroska and WebM Copy Protection (B19)

    /// None of the repository's Matroska or WebM samples is protected, and
    /// the import's one check (`FFmpegAudioConverter.isCopyProtected`) says
    /// so of each, as it does of Windows Media samples.
    func testTheMatroskaSamplesAreNotCopyProtected() throws {
        for sample in ["mka/tones-2tracks.mka", "mka/tones-5.1-ac3.mka", "mka/tones-aac.mka", "mka/tones-long-title.mka",
                       "mka/mp3-form-changes.mka", "mkv/three-tones-flac.mkv", "webm/tones-opus.webm", "webm/tones-vorbis.weba",
                       "ffmpeg-edge/flac-7.1-24bit-65535.mka"] {
            let file = try formatSampleURL(sample)
            XCTAssertFalse(MatroskaHeader.isCopyProtected(fileAt: file), sample)
            XCTAssertFalse(FFmpegAudioConverter.isCopyProtected(file, container: FFmpegContainer.of(fileAt: file)), sample)
        }
    }

    /// A sound track that names a ContentEncryption with an algorithm other
    /// than 0 marks the file protected, in Matroska and in WebM, with every
    /// algorithm the specification lists (1 to 5), whatever the width of the
    /// sizes, an unknown segment size, and a picture's track beside it.
    func testAnEncryptedSoundTrackMarksAMatroskaFileProtected() {
        for algorithm in 1...5 {
            for doctype in ["matroska", "webm"] {
                let file = matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: algorithm)], doctype: doctype)
                XCTAssertTrue(MatroskaHeader.isCopyProtected(bytes: file), "algorithm \(algorithm) in \(doctype)")
            }
        }
        XCTAssertTrue(MatroskaHeader.isCopyProtected(bytes: matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5)], unknownSegmentSize: true)))
        XCTAssertTrue(MatroskaHeader.isCopyProtected(bytes: matroskaFile(tracks: [MatroskaTrack(type: 1), MatroskaTrack(type: 2, encryption: 5)])))
        XCTAssertTrue(MatroskaHeader.isCopyProtected(bytes: matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5), MatroskaTrack(type: 2, encryption: 1)])))
    }

    /// A good file is never called protected: an algorithm of 0 ("not
    /// encrypted"), a compression of the track's headers (which many good
    /// files carry), a picture track alone encrypted, a plain sound track
    /// beside an encrypted one, a file with no sound track or none at all,
    /// and a protection mark that comes only after the first cluster.
    func testAGoodMatroskaFileIsNeverCalledProtected() {
        let plain = MatroskaTrack(type: 2)
        let cases: [(String, [UInt8])] = [
            ("a plain file", matroskaFile(tracks: [plain])),
            ("algorithm 0", matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 0)])),
            ("compression", matroskaFile(tracks: [MatroskaTrack(type: 2, compressed: true)])),
            ("compression and a picture", matroskaFile(tracks: [MatroskaTrack(type: 2, compressed: true), MatroskaTrack(type: 1)])),
            ("an encrypted picture only", matroskaFile(tracks: [MatroskaTrack(type: 1, encryption: 5), plain])),
            ("a plain sound track beside an encrypted one", matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5), plain])),
            ("no sound", matroskaFile(tracks: [MatroskaTrack(type: 1, encryption: 5)])),
            ("no tracks", matroskaFile(tracks: [])),
            ("tracks after a cluster", matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5)], clusterFirst: true)),
            // RFC 9559: a ContentEncryption counts only when its encoding's type is 1, and the type's default is 0.
            ("an encryption in a compression's encoding", matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5, encodingType: 0)])),
            ("an encryption with no encoding type", matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5, encodingType: nil)])),
        ]
        for (name, bytes) in cases {
            XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: bytes), name)
        }
    }

    /// A header that is cut short or lies about its sizes ends the walk
    /// without a trap, and never calls a file protected on what it cannot
    /// read: every cut of a protected file short of the end of its tracks is
    /// told as not protected, the file cut just after them as protected, and
    /// a first element of the biggest size there is, a Tracks of more than
    /// 4 MB, and bytes of no element end the walk. Run on GitHub only, since
    /// nothing damaged is read on the Mac.
    func testADamagedMatroskaHeaderIsJudgedByWhatCameBefore() throws {
        try TestMachine.skipUnlessGitHubRunner("A damaged header could trap the parser")
        let protected = matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5)])
        // The cluster that follows the tracks is 4 + 1 + 3 bytes, its Timecode (E7) the last three.
        let tracksEnd = try XCTUnwrap(protected.lastIndex(of: 0xE7)) - 5
        for length in 0..<tracksEnd {
            XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: Array(protected.prefix(length))), "cut at \(length)")
        }
        XCTAssertTrue(MatroskaHeader.isCopyProtected(bytes: Array(protected.prefix(tracksEnd))))
        let huge: [UInt8] = [0xEC, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]
        XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5)], leading: huge)))
        let tracksOfFourMegabytesAndOne: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x01]
        XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: matroskaFile(tracks: [], leading: tracksOfFourMegabytesAndOne)))
        XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: Array(repeating: 0xFF, count: 64)))
        XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: Array(repeating: 0x00, count: 64)))
        XCTAssertFalse(MatroskaHeader.isCopyProtected(bytes: []))
    }

    /// The file check reads the file: protected bytes written as a file are
    /// protected, and the container is still Matroska. RealMedia has no mark
    /// to look for, so the one check says no of it, and of no container.
    func testTheMatroskaFileCheckReadsTheFile() throws {
        let file = try makeSandboxDirectory("FFmpegSniffMatroska").appendingPathComponent("Locked.mka")
        try Data(matroskaFile(tracks: [MatroskaTrack(type: 2, encryption: 5)])).write(to: file)
        XCTAssertTrue(MatroskaHeader.isCopyProtected(fileAt: file))
        XCTAssertEqual(FFmpegContainer.of(fileAt: file), .matroska)
        XCTAssertTrue(FFmpegAudioConverter.isCopyProtected(file, container: .matroska))
        XCTAssertFalse(FFmpegAudioConverter.isCopyProtected(file, container: .realMedia))
        XCTAssertFalse(FFmpegAudioConverter.isCopyProtected(file, container: nil))
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

// MARK: - Matroska Files Made Here

/// One track of a Matroska file made here: its TrackType (1 picture, 2
/// sound), the ContentEncryption algorithm it names (nil: none), and
/// whether it names a ContentCompression.
struct MatroskaTrack {
    var type: UInt8
    var encryption: Int?
    var compressed = false
    /// The ContentEncodingType written with the encryption: 1, as it is for
    /// an encrypted track; 0 is compression, and `nil` leaves it out (its
    /// default is 0).
    var encodingType: Int? = 1
}

extension XCTestCase {
    /// An EBML size for `count` bytes, in one, two, or eight bytes as the count needs.
    private func ebmlSize(_ count: Int) -> [UInt8] {
        if count < 0x7F { return [0x80 | UInt8(count)] }
        if count < 0x3FFF { return [0x40 | UInt8(count >> 8), UInt8(count & 0xFF)] }
        return [0x01] + (0..<7).reversed().map { UInt8((count >> ($0 * 8)) & 0xFF) }
    }

    /// An EBML element: `identifier`, its size, and `payload`.
    private func ebmlElement(_ identifier: [UInt8], _ payload: [UInt8] = []) -> [UInt8] {
        identifier + ebmlSize(payload.count) + payload
    }

    /// An unsigned-integer element of one byte.
    private func ebmlByte(_ identifier: [UInt8], _ value: Int) -> [UInt8] {
        ebmlElement(identifier, [UInt8(value)])
    }

    /// The bytes of a Matroska file as the specification lays its elements
    /// out: the EBML header of `doctype`, then a segment of a Void element
    /// (or `leading`'s bytes, as they are), the tracks, and a cluster; no
    /// sound to decode, since the protection check reads only the headers.
    /// `clusterFirst` puts the cluster before the tracks, and
    /// `unknownSegmentSize` gives the segment the size of a file written live.
    func matroskaFile(tracks: [MatroskaTrack], doctype: String = "matroska", unknownSegmentSize: Bool = false,
                      clusterFirst: Bool = false, leading: [UInt8]? = nil) -> [UInt8] {
        let header = ebmlElement([0x1A, 0x45, 0xDF, 0xA3], ebmlByte([0x42, 0x86], 1) + ebmlElement([0x42, 0x82], Array(doctype.utf8)))
        let entries = tracks.enumerated().flatMap { index, track -> [UInt8] in
            var fields = ebmlByte([0xD7], index + 1) + ebmlByte([0x83], Int(track.type)) + ebmlElement([0x86], Array("A_TEST".utf8))
            var encodings: [UInt8] = ebmlByte([0x50, 0x31], 0) + ebmlByte([0x50, 0x32], 1)
            if let algorithm = track.encryption {
                if let type = track.encodingType { encodings += ebmlByte([0x50, 0x33], type) }
                encodings += ebmlElement([0x50, 0x35], ebmlByte([0x47, 0xE1], algorithm) + ebmlElement([0x47, 0xE2], [1, 2, 3]))
            }
            if track.compressed {
                encodings += ebmlByte([0x50, 0x33], 0)
                encodings += ebmlElement([0x50, 0x34], ebmlByte([0x42, 0x54], 3) + ebmlElement([0x42, 0x55], [0xFF]))
            }
            if track.encryption != nil || track.compressed {
                fields += ebmlElement([0x6D, 0x80], ebmlElement([0x62, 0x40], encodings))
            }
            return ebmlElement([0xAE], fields)
        }
        let padding = leading ?? ebmlElement([0xEC], [UInt8](repeating: 0, count: 200))
        let cluster = ebmlElement([0x1F, 0x43, 0xB6, 0x75], ebmlByte([0xE7], 0))
        let tracksElement = tracks.isEmpty ? [] : ebmlElement([0x16, 0x54, 0xAE, 0x6B], entries)
        let children = clusterFirst ? padding + cluster + tracksElement : padding + tracksElement + cluster
        let segmentSize: [UInt8] = unknownSegmentSize ? [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] : ebmlSize(children.count)
        return header + [0x18, 0x53, 0x80, 0x67] + segmentSize + children
    }
}
