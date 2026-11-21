import XCTest
@testable import TextMouth

/// What the import of a format only FFmpeg reads writes, decided before
/// anything is decoded (FMT31, FMT32, FMT50): the target of each sound the
/// helper reports, the limits of a source that says no length or one it
/// cannot hold, the formats' names, the failure each way a run of the helper
/// can end in, and the sentences a listener hears. Pure functions of their
/// values: nothing runs. `FFmpegHelperStreamTests` reads the reports
/// themselves; `FFmpegImportConversionTests` runs the helper.
final class FFmpegImportPlanTests: XCTestCase {
    /// The report of a stream whose INFO is the WMA sample's with `changes`
    /// (a nil value leaves the key out).
    private func report(_ changes: [(String, String?)], tags: [(String, String)] = []) throws -> FFmpegReport {
        let info = changes.reduce(FFmpegTestStream.wmaInfo) { FFmpegTestStream.replacing($1.0, with: $1.1, in: $0) }
        return try XCTUnwrap(FFmpegReport(info: Dictionary(uniqueKeysWithValues: info), fileTags: [], streamTags: tags, chapters: []))
    }

    // MARK: - What Each Sound Becomes

    /// A lossy sound becomes AAC at its own bit rate rounded up to a
    /// standard one, at its own sample rate where AAC takes it; AAC itself
    /// too, as every lossy sound is now (the helper hands over samples, not
    /// packets); more than two channels are mixed to stereo; a rate unknown
    /// is taken as 64 kbit/s a channel, and a file of sound alone lends its
    /// own to its one stream.
    func testHowEachLossySoundIsWritten() throws {
        let wma = try FFmpegAudioConverter.plan(for: try report([]), fileName: "a.wma")
        let wmaInfo = ImportAudioConverter.SourceInfo(
            sampleRate: 22_050, channels: 1, duration: 3.999, formatID: "wmav1", bitsPerSample: nil, isLossless: false
        )
        XCTAssertEqual(wma.info, wmaInfo)
        XCTAssertEqual(wma.target, ImportAudioConverter.target(for: wmaInfo, averageBitRate: 32_000))
        XCTAssertNil(wma.target.appleLosslessBitDepth)

        let aac = try FFmpegAudioConverter.plan(for: try report([("codec", "aac"), ("channels", "2"), ("bit_rate", "64000")]), fileName: "a.flv")
        XCTAssertNil(aac.target.appleLosslessBitDepth)
        XCTAssertEqual(aac.target.channels, 2)
        XCTAssertGreaterThanOrEqual(aac.target.bitRate ?? 0, 64_000)

        let surround = try FFmpegAudioConverter.plan(
            for: try report([("codec", "ac3"), ("channels", "6"), ("sample_rate", "48000"), ("bit_rate", "384000")]), fileName: "a.mka"
        )
        XCTAssertEqual(surround.target.channels, 2)
        XCTAssertEqual(surround.info.channels, 6)

        let shared = try FFmpegAudioConverter.plan(
            for: try report([("codec", "opus"), ("sample_rate", "48000"), ("bit_rate", nil), ("format_bit_rate", "96000")]),
            fileName: "a.webm"
        )
        let opusInfo = ImportAudioConverter.SourceInfo(
            sampleRate: 48_000, channels: 1, duration: 3.999, formatID: "opus", bitsPerSample: nil, isLossless: false
        )
        XCTAssertEqual(shared.target, ImportAudioConverter.target(for: opusInfo, averageBitRate: 96_000))
        let unknown = try FFmpegAudioConverter.plan(
            for: try report([("codec", "opus"), ("sample_rate", "48000"), ("bit_rate", nil), ("format_bit_rate", nil)]),
            fileName: "a.webm"
        )
        XCTAssertEqual(unknown.target, ImportAudioConverter.target(for: opusInfo, averageBitRate: Double(AudioRenderSettings.bitRatePerChannel)))
    }

    /// A lossless sound becomes Apple Lossless of its own depth: 16 bits for
    /// 8 and 16, 24 as it is, 20 widened to 24 (B15), 32 for 32, and 24 for floating point,
    /// which keeps no depth of whole bits; never a bit rate.
    func testHowEachLosslessSoundIsWritten() throws {
        for (codec, format, bits, depth) in [
            ("flac", "s16", "16", 16), ("flac", "s32", "24", 24), ("pcm_u8", "s16", "8", 16), ("wmalossless", "s32", "24", 24),
            ("truehd", "s32", "20", 24), ("pcm_s32le", "s32", "32", 32), ("pcm_f32le", "f32", "32", 24), ("wavpack", "f32", "32", 24),
        ] {
            let lossless = try FFmpegAudioConverter.plan(
                for: try report([("codec", codec), ("sample_format", format), ("bits", bits), ("channels", "2")]), fileName: "a.mka"
            )
            XCTAssertEqual(lossless.target.appleLosslessBitDepth, depth, "\(codec) \(format) \(bits)")
            XCTAssertNil(lossless.target.bitRate, codec)
            XCTAssertTrue(lossless.info.isLossless, codec)
        }
    }

    /// A report of no usable sound (a rate or channels no file has, or
    /// samples of no form the reader knows) plans nothing: the file holds no
    /// sound to import.
    func testNoUsableSoundPlansNothing() throws {
        for changes in [[("sample_rate", "0")], [("channels", "0")], [("sample_format", "s24")]] {
            XCTAssertThrowsError(try FFmpegAudioConverter.plan(for: try report(changes), fileName: "Clip.mkv")) { error in
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .noSound(fileName: "Clip.mkv"), "\(changes)")
            }
        }
    }

    /// The samples the writer is handed are described as the report says:
    /// rate, channels, depth, floats, losslessness, and loudspeakers.
    func testTheSamplesAreDescribedForTheWriter() throws {
        let floats = FFmpegAudioConverter.samplesStream(of: try report([("channels", "2"), ("channel_mask", "3")]))
        XCTAssertEqual(floats, OwnAudioStream(sampleRate: 22_050, channels: 2, bitsPerSample: 32, isFloat: true, isLossless: false,
                                              frames: 0, channelMask: 3))
        let flac = FFmpegAudioConverter.samplesStream(of: try report([("codec", "flac"), ("sample_format", "s32"), ("bits", "24"),
                                                                      ("channel_mask", "0")]))
        XCTAssertEqual(flac, OwnAudioStream(sampleRate: 22_050, channels: 1, bitsPerSample: 24, isFloat: false, isLossless: true,
                                            frames: 0, channelMask: nil))
    }

    /// The codecs that keep every bit of their source become Apple
    /// Lossless; the rest, A-law and μ-law PCM among them, become AAC.
    func testWhichCodecsAreLossless() {
        for codec in ["flac", "alac", "wmalossless", "ralf", "mlp", "truehd", "tta", "wavpack", "ape", "pcm_s16le", "pcm_s24be",
                      "pcm_f32le", "pcm_u8"] {
            XCTAssertTrue(FFmpegAudioConverter.isLossless(codec: codec), codec)
        }
        for codec in ["wmav1", "wmav2", "wmapro", "wmavoice", "opus", "vorbis", "speex", "mp3", "aac", "ac3", "cook",
                      "musepack7", "musepack8", "pcm_alaw", "pcm_mulaw", ""] {
            XCTAssertFalse(FFmpegAudioConverter.isLossless(codec: codec), codec)
        }
    }

    // MARK: - The Limits

    /// A source that does not say its length is taken, for its limits only,
    /// to last as long as 6 kbit/s would make it, at most a year.
    func testAnUnknownLengthIsAssumedLongForTheLimits() {
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: 6_000), 8)
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: -5), 0)
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: .max), FFmpegReport.maximumDuration)
    }

    /// A source that says no length may write 50 times its size, and at
    /// least 64 MB, so its length assumed from its size cannot let it fill
    /// the disk; a size too large to multiply has no such cap.
    func testASourceOfNoLengthMayWriteFiftyTimesItsSize() {
        let floor: Int64 = 64 * 1_048_576
        XCTAssertEqual(FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: 0), floor)
        XCTAssertEqual(FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: -1), floor)
        // The 159 KB of silence that became 55 MB may now write 64 MB.
        XCTAssertEqual(FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: 159_000), floor)
        XCTAssertEqual(FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: 100_000_000), 5_000_000_000)
        XCTAssertEqual(FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: .max), .max)
    }

    /// A stated length is believed only when the file's size can hold it at
    /// 1 kbit/s, as afinfo's is; one past that is no length, so a header
    /// that lies cannot lift the time limit or the output cap.
    func testALengthTheFileCannotHoldIsNoLength() {
        XCTAssertNil(FFmpegAudioConverter.believedDuration(nil, ofFileNamed: "a.wma", bytes: 20_000))
        XCTAssertEqual(FFmpegAudioConverter.believedDuration(4, ofFileNamed: "a.wma", bytes: 20_000), 4)
        XCTAssertEqual(FFmpegAudioConverter.believedDuration(160, ofFileNamed: "a.wma", bytes: 20_000), 160)
        XCTAssertNil(FFmpegAudioConverter.believedDuration(160.5, ofFileNamed: "a.wma", bytes: 20_000))
        XCTAssertNil(FFmpegAudioConverter.believedDuration(100_000, ofFileNamed: "a.wma", bytes: 20_000))
        XCTAssertNil(FFmpegAudioConverter.believedDuration(1, ofFileNamed: "a.wma", bytes: -1))
    }

    /// The bundled helper's limits: a decode as afconvert's but for a
    /// minute's stall, and a probe ffprobe's of before (30 seconds and one
    /// more for each 20 MB, 512 MB, the whole run's stall allowance).
    func testTheHelpersLimits() {
        let decode = FFmpegAudioConverter.Tool.bundled.limits(600)
        XCTAssertEqual(decode, WatchedProcess.Limits(maximumSeconds: 120, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: 60))
        let probe = FFmpegAudioConverter.Tool.bundled.probeLimits(40_000_000)
        XCTAssertEqual(probe, WatchedProcess.Limits(maximumSeconds: 32, maximumResidentBytes: 536_870_912, maximumStalledSeconds: 32))
    }

    // MARK: - How a Run Ends

    /// Each exit status of the helper (TextMouthFFmpegProtocol.h) has its
    /// sentence, and any other the converter's code.
    func testEachExitStatusHasItsFailure() {
        let limits = WatchedProcess.Limits(maximumSeconds: 10, maximumResidentBytes: 1, maximumStalledSeconds: 10)
        let words = [Int32](arrayLiteral: 2, 3, 4, 5, 6, 7, 9, 12, 13, 70, 71, 1, 8, 10, 99).map {
            FFmpegAudioConverter.failure(forExitStatus: $0, fileName: "Lecture.wma", kind: "WMA", limits: limits).localizedDescription
        }
        XCTAssertEqual(words, [
            "The audio file Lecture.wma could not be read for converting.",
            "TextMouth can't read “Lecture.wma” as WMA. It may be damaged, or named for another format.",
            "“Lecture.wma” holds no sound to import.",
            "TextMouth can't convert the sound of “Lecture.wma”: it is in a kind of audio it does not read.",
            "The audio file Lecture.wma is damaged, so it could not be converted.",
            "TextMouth can't convert “Lecture.wma”: its sound changes rate or channels partway through, by more than it can follow.",
            "Converting Lecture.wma was stopped because it needed more memory than it may use.",
            "TextMouth's converter could not make itself safe before reading “Lecture.wma”, so it did not read the file. "
                + "Install TextMouth again, then import the file again.",
            "TextMouth can't convert “Lecture.wma”: part of its sound is in one piece too large to decode.",
            "TextMouth's converter stopped unexpectedly while reading “Lecture.wma”. The file may be damaged.",
            "Converting Lecture.wma was stopped because it used more than 40 seconds of processor time.",
            "Converting Lecture.wma failed (the converter ended with code 1).",
            "Converting Lecture.wma failed (the converter ended with code 8).",
            "Converting Lecture.wma failed (the converter ended with code 10).",
            "Converting Lecture.wma failed (the converter ended with code 99).",
        ])
    }

    /// How a run ends decides its failure: a kill by the watchdog first; a
    /// whole stream is success however the helper then ended; a stream that
    /// ended early is what the helper's ending says (a status, a signal, or
    /// a clean exit too soon); a stream that broke the protocol is unreadable;
    /// a cancellation and the reader's own errors are themselves.
    func testHowARunEndsDecidesItsFailure() {
        let limits = WatchedProcess.Limits(maximumSeconds: 10, maximumResidentBytes: 1, maximumStalledSeconds: 10)
        /// The failure of a run that ended so, as words.
        func failure(_ ending: WatchedProcess.Ending, _ read: Result<Int, any Error>) -> String? {
            FFmpegAudioConverter.failure(of: ending, read: read, fileName: "a.wma", kind: "WMA", limits: limits, logTag: "TEST")
                .map { "\($0)" }
        }
        let early = Result<Int, any Error>.failure(FFmpegHelperStream.StreamError.endedEarly)
        XCTAssertNil(failure(.init(outcome: .exited(status: 0)), .success(1)))
        XCTAssertNil(failure(.init(outcome: .exited(status: 9), signal: 9), .success(1)))
        XCTAssertEqual(failure(.init(outcome: .killed(.madeNoProgress(seconds: 60))), .success(1)),
                       "\(ImportAudioConverter.Failure.killed(fileName: "a.wma", reason: "its output did not grow for 60 seconds"))")
        // The reader's own stop at the output cap is the kill the watchdog would have made.
        XCTAssertEqual(failure(.init(outcome: .exited(status: 9), signal: 9), .failure(FFmpegAudioConverter.WroteTooMuch(bytes: 5_242_880))),
                       "\(ImportAudioConverter.Failure.killed(fileName: "a.wma", reason: "its output passed 5 MB"))")
        XCTAssertEqual(failure(.init(outcome: .exited(status: 0)), early), "\(FFmpegAudioConverter.Failure.endedEarly(fileName: "a.wma"))")
        XCTAssertEqual(failure(.init(outcome: .exited(status: 3)), early),
                       "\(FFmpegAudioConverter.Failure.notRecognized(fileName: "a.wma", kind: "WMA"))")
        XCTAssertEqual(failure(.init(outcome: .exited(status: 11), signal: 11), early), "\(FFmpegAudioConverter.Failure.crashed(fileName: "a.wma"))")
        XCTAssertEqual(failure(.init(outcome: .couldNotStart), early),
                       "\(ImportAudioConverter.Failure.processFailed(fileName: "a.wma", status: -1))")
        for broken in [FFmpegHelperStream.StreamError.damaged, .otherProtocol] {
            XCTAssertEqual(failure(.init(outcome: .exited(status: 9), signal: 9), .failure(broken)),
                           "\(FFmpegAudioConverter.Failure.unreadableStream(fileName: "a.wma"))")
        }
        XCTAssertEqual(failure(.init(outcome: .exited(status: 9), signal: 9), .failure(CancellationError())), "\(CancellationError())")
        // A writer's error by its domain and code; the domain is a made-up one, since the iPhone's unit tests may
        // name no audio framework, not even in a string (Scripts/agents/ios_ui_tests.py).
        let own = ImportAudioConverter.Failure.notWritten(fileName: "a.wma", reason: "TestWriterErrorDomain -11800")
        XCTAssertEqual(failure(.init(outcome: .exited(status: 9), signal: 9), .failure(own)), "\(own)")
    }

    // MARK: - The Words

    /// Every extension FFmpeg converts has a name people say, and Speex in
    /// Ogg is Speex whatever its name; .mpp, Microsoft Project's too, is not
    /// one of them (the TODO's FU-FFMPEG item).
    func testEveryFormatHasItsName() {
        let names = FFmpegAudioConverter.extensions.sorted().map { "\($0): \(FFmpegImportWording.kindName(forExtension: $0) ?? "none")" }
        XCTAssertEqual(names, [
            "asf: Windows Media", "avi: AVI video", "flv: Flash video", "mka: Matroska", "mkv: Matroska", "mp+: Musepack",
            "mpc: Musepack", "ra: RealMedia", "rm: RealMedia", "rmvb: RealMedia", "spx: Speex",
            "weba: WebM", "webm: WebM", "wma: WMA", "wmv: WMV video",
        ])
        XCTAssertNil(FFmpegImportWording.kindName(forExtension: "mpp"))
        XCTAssertFalse(FFmpegAudioConverter.converts(URL(fileURLWithPath: "/nonexistent/Schedule.mpp")))
        XCTAssertNil(FFmpegImportWording.kindName(forExtension: "mp3"))
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.ogg"), container: .oggSpeex), "Speex")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.WMA"), container: .asf), "WMA")
        // A name that says nothing of the format is named by the bytes' container.
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.xyz"), container: .asf), "Windows Media")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk"), container: .matroska), "Matroska")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.xyz"), container: nil), "XYZ")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk"), container: nil), "this format")
        let containers = FFmpegContainer.allCases.map { "\($0.rawValue): \(FFmpegImportWording.kindName(of: $0))" }
        XCTAssertEqual(containers, [
            "asf: Windows Media", "matroska: Matroska", "flv: Flash video", "avi: AVI video", "realMedia: RealMedia",
            "musepack7: Musepack", "musepack8: Musepack", "oggSpeex: Speex", "ogg: Ogg",
        ])
    }

    /// The notice of the tracks a book of several left out (review9 finding
    /// 2): when the app's converter is missing, and for files that hold no
    /// sound, with at most five named; nothing when none was left out or the
    /// converter is there, the Mac's helper or the iPhone's session in the
    /// app (FMT54), which leaves out only what holds no sound.
    func testTheNoticeOfTracksLeftOut() {
        XCTAssertEqual(
            FFmpegImportWording.tracksLeftOutNotice(
                needingConverter: FFmpegImportWording.leftOutNeedingConverter(["Trailer.avi", "Intro.wmv"], located: .missing),
                holdingNoSound: []
            ),
            "TextMouth left out 2 files, “Trailer.avi” and “Intro.wmv”, which need TextMouth's converter, missing from the app. "
                + "Install TextMouth again, then import the book again."
        )
        XCTAssertEqual(
            FFmpegImportWording.tracksLeftOutNotice(
                needingConverter: FFmpegImportWording.leftOutNeedingConverter(["Trailer.avi"], located: .inProcess),
                holdingNoSound: ["a.spx", "b.spx"]
            ),
            "TextMouth left out 2 files, “a.spx” and “b.spx”, which hold no sound it can read."
        )
        XCTAssertNil(FFmpegImportWording.tracksLeftOutNotice(needingConverter: nil, holdingNoSound: []))
        XCTAssertNil(FFmpegImportWording.leftOutNeedingConverter([], located: .missing))
        XCTAssertNil(FFmpegImportWording.leftOutNeedingConverter(["a.avi"], located: .found(URL(fileURLWithPath: "/usr/bin/true"))))
        XCTAssertNil(FFmpegImportWording.leftOutNeedingConverter(["a.avi"], located: .inProcess))
        XCTAssertEqual(
            FFmpegImportWording.leftOutFiles((1...7).map { "\($0).wmv" }),
            "7 files, “1.wmv”, “2.wmv”, “3.wmv”, “4.wmv”, “5.wmv”, and 2 more"
        )
    }

    /// The sentences a listener hears, word for word: each names the file or
    /// the format, says what to do when something can be done, holds no
    /// symbol VoiceOver would spell out, and none sends anyone to Homebrew:
    /// the import needs no installed ffmpeg.
    func testTheSentencesAListenerHears() {
        let failures: [(FFmpegAudioConverter.Failure, String)] = [
            (.helperMissing(kind: "WMA"),
             "TextMouth can't convert WMA files because its converter is missing from the app. Install TextMouth again, "
                + "then import the file again."),
            (.copyProtected, "TextMouth cannot open copy-protected files."),
            (.notRecognized(fileName: "Lecture.wma", kind: "WMA"),
             "TextMouth can't read “Lecture.wma” as WMA. It may be damaged, or named for another format."),
            (.noSound(fileName: "Clip.mkv"), "“Clip.mkv” holds no sound to import."),
            (.soundNotDecoded(fileName: "Clip.avi"),
             "TextMouth can't convert the sound of “Clip.avi”: it is in a kind of audio it does not read."),
            (.formChanged(fileName: "Radio.mkv"),
             "TextMouth can't convert “Radio.mkv”: its sound changes rate or channels partway through, by more than it can follow."),
            (.notConfined(fileName: "Lecture.wma"),
             "TextMouth's converter could not make itself safe before reading “Lecture.wma”, so it did not read the file. "
                + "Install TextMouth again, then import the file again."),
            (.crashed(fileName: "Lecture.wma"),
             "TextMouth's converter stopped unexpectedly while reading “Lecture.wma”. The file may be damaged."),
            (.endedEarly(fileName: "Lecture.wma"),
             "TextMouth's converter stopped before the end of “Lecture.wma”, so it could not be imported."),
            (.unreadableStream(fileName: "Lecture.wma"),
             "TextMouth's converter gave back audio of “Lecture.wma” that TextMouth could not read. Install TextMouth again, "
                + "then import the file again."),
        ]
        for (failure, words) in failures {
            XCTAssertEqual(failure.localizedDescription, words)
            let unnamed = words.replacingOccurrences(of: "“Lecture.wma”", with: "")
                .replacingOccurrences(of: "“Clip.mkv”", with: "").replacingOccurrences(of: "“Clip.avi”", with: "")
                .replacingOccurrences(of: "“Radio.mkv”", with: "")
            XCTAssertNil(unnamed.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}<>/\\|*#@~`^;")), words)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("brew"), words)
            XCTAssertFalse(words.contains("ffmpeg"), words)
        }
        XCTAssertEqual(
            ImportAudioConverter.Failure.checkFailed(fileName: "Talk.webm", reason: FFmpegImportWording.convertedFileIsSilent)
                .localizedDescription,
            "The audio converted from Talk.webm failed its check: it lasts no time."
        )
        // The iPhone's FFmpeg engine (FMT54) says its two sentences of its own work, which a listener hears after
        // the import's words: a call abandoned past its time, and every one refused after it.
        XCTAssertEqual(
            InProcessEngine.Failure.abandoned(work: FFmpegImportWording.inAppWork, limit: 61.2).errorDescription,
            "TextMouth stopped the audio conversion because it ran longer than 62 seconds, "
                + "and won't try again until TextMouth is closed and opened again."
        )
        XCTAssertEqual(
            InProcessEngine.Failure.refused(work: FFmpegImportWording.inAppWork).errorDescription,
            "TextMouth stopped the audio conversion earlier because it took too long, "
                + "and won't try again until TextMouth is closed and opened again."
        )
    }
}
