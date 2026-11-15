import XCTest
@testable import TextMouth

/// What the ffmpeg import decides before anything runs (FMT31, FMT32): what
/// it believes of ffprobe's report, which sound it takes, the tags it
/// carries, how it writes the sound, ffmpeg's exact arguments, and the
/// sentences a listener hears. The reports are ffprobe's own JSON, as it
/// printed it for the repository's samples (trimmed), so no test here needs
/// ffmpeg, and all run on GitHub's runners.
final class FFmpegImportPlanTests: XCTestCase {
    // MARK: - ffprobe's Reports

    /// ffprobe's report of wma/tones.wma: one WMA 2 stream, no default.
    private let wmaReport = """
    {"streams": [{"index": 0, "codec_name": "wmav2", "codec_type": "audio", "sample_fmt": "fltp",
      "sample_rate": "22050", "channels": 1, "bit_rate": "32000", "duration": "3.000000",
      "disposition": {"default": 0, "attached_pic": 0}}],
     "format": {"format_name": "asf", "duration": "3.000000", "bit_rate": "44538",
      "tags": {"title": "Tones", "artist": "TextMouth tests", "encoder": "Lavf61.7.100"}}}
    """

    /// ffprobe's report of mka/tones-2tracks.mka: two Opus streams, the
    /// first the default, each named and in a language; Matroska keeps their
    /// lengths in tags, and the file's tags in capitals.
    private let twoTrackReport = """
    {"streams": [
      {"index": 0, "codec_name": "opus", "codec_type": "audio", "sample_rate": "48000", "channels": 1,
       "disposition": {"default": 1, "attached_pic": 0},
       "tags": {"language": "eng", "title": "Narration", "DURATION": "00:00:03.008000000"}},
      {"index": 1, "codec_name": "opus", "codec_type": "audio", "sample_rate": "48000", "channels": 1,
       "disposition": {"default": 0, "attached_pic": 0},
       "tags": {"language": "deu", "title": "Kommentar", "DURATION": "00:00:03.008000000"}}],
     "format": {"format_name": "matroska,webm", "duration": "3.008000", "bit_rate": "66537",
      "tags": {"title": "Tones in Matroska", "ARTIST": "TextMouth tests"}}}
    """

    /// ffprobe's report of avi/tones-mp3.avi: a picture track first, then
    /// MP3 sound shorter than the file.
    private let aviReport = """
    {"streams": [
      {"index": 0, "codec_name": "mjpeg", "codec_type": "video", "duration": "5.000000",
       "disposition": {"default": 0, "attached_pic": 0}},
      {"index": 1, "codec_name": "mp3", "codec_type": "audio", "sample_rate": "22050", "channels": 1,
       "bit_rate": "32000", "duration": "4.075102", "disposition": {"default": 0, "attached_pic": 0}}],
     "format": {"format_name": "avi", "duration": "5.000000", "bit_rate": "49920",
      "tags": {"artist": "TextMouth Test", "title": "Three Tones"}}}
    """

    /// ffprobe's report of rm/tones.ra: RealAudio whose file says no length
    /// (0) and no bit rate.
    private let realAudioReport = """
    {"streams": [{"index": 0, "codec_name": "ra_144", "codec_type": "audio", "sample_rate": "8000",
      "channels": 1, "bit_rate": "8000", "duration": "0.000000", "disposition": {"default": 0, "attached_pic": 0}}],
     "format": {"format_name": "rm", "duration": "0.000000", "tags": {"title": "Three Tones"}}}
    """

    /// The report in `json`, failing the test when it does not parse.
    private func report(_ json: String) throws -> FFprobeReport {
        try XCTUnwrap(FFprobeReport(json: Data(json.utf8)), "The report did not parse")
    }

    /// A report of one stream described by `stream` (JSON members), in a
    /// file of `format` members.
    private func report(stream: String, format: String = #""format_name": "matroska,webm""#) throws -> FFprobeReport {
        try report(#"{"streams": [{"index": 0, "codec_type": "audio", "#
            + stream + #", "disposition": {"default": 0}}], "format": {"# + format + "}}")
    }

    /// The numbers and names of each stream are read, whether ffprobe wrote
    /// them as numbers or strings, and Matroska's tags give a stream's
    /// length when ffprobe has none; tag keys are lowercase.
    func testTheReportsAreRead() throws {
        let wma = try report(wmaReport)
        XCTAssertEqual(wma.formatName, "asf")
        XCTAssertEqual(wma.duration, 3)
        XCTAssertEqual(wma.bitRate, 44_538)
        XCTAssertEqual(wma.tags, ["title": "Tones", "artist": "TextMouth tests", "encoder": "Lavf61.7.100"])
        let stream = try XCTUnwrap(wma.streams.first)
        XCTAssertEqual(
            [String(stream.index), stream.codecType, stream.codecName, String(describing: stream.sampleRate),
             String(describing: stream.channels), String(describing: stream.bitRate), String(describing: stream.duration)],
            ["0", "audio", "wmav2", "Optional(22050.0)", "Optional(1)", "Optional(32000)", "Optional(3.0)"]
        )
        XCTAssertFalse(stream.isDefault)

        let mka = try report(twoTrackReport)
        XCTAssertEqual(mka.tags["artist"], "TextMouth tests")
        XCTAssertEqual(mka.streams.map(\.duration), [3.008, 3.008])
        XCTAssertEqual(mka.streams.map(\.isDefault), [true, false])
        XCTAssertEqual(mka.streams.map { $0.tags["title"] }, ["Narration", "Kommentar"])
    }

    /// No number that is not plausible is believed: a length of zero or past
    /// a year, a sample rate of none or past 768 kHz, no channels or more
    /// than 64, a bit rate of none or past 100 Mbit/s; a stream with no
    /// believed rate or channels is no sound to convert.
    func testImplausibleNumbersAreNotBelieved() throws {
        let realAudio = try report(realAudioReport)
        XCTAssertNil(realAudio.duration)
        XCTAssertNil(realAudio.streams.first?.duration)
        let wild = try report(stream: #""codec_name": "opus", "sample_rate": "-1", "channels": 1000, "bit_rate": "1e12", "duration": "1e30""#)
        let stream = try XCTUnwrap(wild.streams.first)
        XCTAssertNil(stream.sampleRate)
        XCTAssertNil(stream.channels)
        XCTAssertNil(stream.bitRate)
        XCTAssertNil(stream.duration)
        XCTAssertFalse(stream.isUsableAudio)
        XCTAssertNil(wild.chosenAudio)
        let tooFast = try report(stream: #""codec_name": "opus", "sample_rate": "800000", "channels": 2"#)
        XCTAssertNil(tooFast.streams.first?.sampleRate)
    }

    /// What is no ffprobe report is nil: not JSON, JSON of another shape,
    /// or a report of no streams.
    func testWhatIsNoReportIsNil() {
        for text in ["", "not json", "[1, 2]", #"{"format": {}}"#, #"{"streams": []}"#, #"{"streams": "none"}"#] {
            XCTAssertNil(FFprobeReport(json: Data(text.utf8)), text)
        }
    }

    /// Matroska's length tag is read as hours, minutes, and seconds, and
    /// anything else is no length; mkvmerge's statistics give a stream's bit
    /// rate when ffprobe has none.
    func testMatroskaTagsGiveLengthsAndBitRates() throws {
        XCTAssertEqual(FFprobeReport.matroskaDuration("01:02:03.5"), 3_723.5)
        for text in [nil, "", "3.5", "1:2", "a:b:c", "-1:00:00"] {
            XCTAssertNil(FFprobeReport.matroskaDuration(text), String(describing: text))
        }
        let tagged = try report(stream: #""codec_name": "vorbis", "sample_rate": "44100", "channels": 2, "tags": {"BPS-eng": "96000", "DURATION-eng": "00:01:00.000"}"#)
        XCTAssertEqual(tagged.streams.first?.bitRate, 96_000)
        XCTAssertEqual(tagged.streams.first?.duration, 60)
        // ffprobe's 0, a figure it could not work out, gives way to the tags.
        let zeroes = try report(stream: #""codec_name": "vorbis", "sample_rate": "44100", "channels": 2, "bit_rate": "0", "duration": "0.000000", "tags": {"BPS": "64000", "DURATION": "00:00:30.000"}"#)
        XCTAssertEqual(zeroes.streams.first?.bitRate, 64_000)
        XCTAssertEqual(zeroes.streams.first?.duration, 30)
    }

    // MARK: - The Sound Taken

    /// The sound taken is the first marked default, else the first; a
    /// picture track, a cover, and subtitles are never taken, and a file of
    /// none holds no sound.
    func testTheDefaultSoundIsTakenElseTheFirst() throws {
        XCTAssertEqual(try report(twoTrackReport).chosenAudio?.index, 0)
        XCTAssertEqual(try report(aviReport).chosenAudio?.index, 1)
        let secondDefault = try report("""
        {"streams": [
          {"index": 0, "codec_type": "video", "codec_name": "h264", "disposition": {"default": 1}},
          {"index": 1, "codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2, "disposition": {"default": 0}},
          {"index": 2, "codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2, "disposition": {"default": 1}},
          {"index": 3, "codec_type": "subtitle", "codec_name": "ass", "disposition": {"default": 1}}],
         "format": {"format_name": "matroska,webm"}}
        """)
        XCTAssertEqual(secondDefault.chosenAudio?.index, 2)
        let silent = try report("""
        {"streams": [{"index": 0, "codec_type": "video", "codec_name": "mjpeg", "disposition": {"default": 1, "attached_pic": 1}}],
         "format": {"format_name": "matroska,webm"}}
        """)
        XCTAssertNil(silent.chosenAudio)
        XCTAssertThrowsError(try FFmpegAudioConverter.plan(for: silent, container: .matroska, fileName: "Clip.mkv", aacEncoder: "aac_at")) {
            XCTAssertEqual($0 as? FFmpegAudioConverter.Failure, .noSound(fileName: "Clip.mkv"))
        }
    }

    /// A stream's own length and bit rate come first; a file of sound alone
    /// shares its bit rate among its sound streams, and a file with pictures
    /// gives none, since its rate is the pictures' too.
    func testLengthsAndBitRatesOfTheSoundTaken() throws {
        let avi = try report(aviReport)
        let sound = try XCTUnwrap(avi.chosenAudio)
        XCTAssertEqual(avi.duration(of: sound), 4.075102)
        XCTAssertEqual(avi.bitRate(of: sound), 32_000)
        let pictures = try report("""
        {"streams": [
          {"index": 0, "codec_type": "video", "codec_name": "h264", "disposition": {"default": 1}},
          {"index": 1, "codec_type": "audio", "codec_name": "opus", "sample_rate": "48000", "channels": 2, "disposition": {"default": 1}}],
         "format": {"format_name": "matroska,webm", "duration": "60.0", "bit_rate": "2000000"}}
        """)
        let opus = try XCTUnwrap(pictures.chosenAudio)
        XCTAssertNil(pictures.bitRate(of: opus))
        XCTAssertEqual(pictures.duration(of: opus), 60)
        let mka = try report(twoTrackReport)
        XCTAssertEqual(mka.bitRate(of: try XCTUnwrap(mka.chosenAudio)), 66_537 / 2)
    }

    // MARK: - Tags

    /// A book takes the file's own tags, and the stream's where the file
    /// names none (Ogg keeps its comments on the stream); the conversion
    /// writes itself only the carried keys the file leaves to the stream.
    func testTheFilesTagsComeFirstAndTheStreamsFillTheGaps() throws {
        let speex = try report(stream: #""codec_name": "speex", "sample_rate": "16000", "channels": 1, "tags": {"title": "Speex Title", "ARTIST": "Speex Artist", "encoder": "Lavc"}"#,
                               format: #""format_name": "ogg", "tags": {"album": "Album"}"#)
        let stream = try XCTUnwrap(speex.chosenAudio)
        XCTAssertEqual(speex.tags(of: stream), ["album": "Album", "title": "Speex Title", "artist": "Speex Artist", "encoder": "Lavc"])
        XCTAssertEqual(speex.streamTagsToCarry(of: stream).map { "\($0.key)=\($0.value)" }, ["title=Speex Title", "artist=Speex Artist"])
        let mka = try report(twoTrackReport)
        // The file names its title; a track's title is the track's name, not the book's.
        XCTAssertEqual(mka.tags(of: try XCTUnwrap(mka.chosenAudio))["title"], "Tones in Matroska")
        XCTAssertTrue(mka.streamTagsToCarry(of: try XCTUnwrap(mka.chosenAudio)).isEmpty)
    }

    // MARK: - The Plan

    /// Lossy sound becomes AAC from the stream's own bit rate, not the
    /// file's, at its own length; AAC of at most two channels is copied;
    /// lossless sound becomes Apple Lossless of its own depth; more than two
    /// channels are mixed to stereo; a rate unknown is taken as 64 kbit/s a
    /// channel.
    func testHowEachSoundIsWritten() throws {
        let avi = try FFmpegAudioConverter.plan(for: try report(aviReport), container: .avi, fileName: "a.avi", aacEncoder: "aac_at")
        XCTAssertEqual(avi.encoding, .aac(encoder: "aac_at"))
        XCTAssertEqual(avi.streamIndex, 1)
        XCTAssertEqual(avi.duration, 4.075102)
        let mp3Info = ImportAudioConverter.SourceInfo(
            sampleRate: 22_050, channels: 1, duration: 4.075102, formatID: "mp3", bitsPerSample: nil, isLossless: false
        )
        XCTAssertEqual(avi.target, ImportAudioConverter.target(for: mp3Info, averageBitRate: 32_000))

        let aac = try FFmpegAudioConverter.plan(
            for: try report(stream: #""codec_name": "aac", "sample_rate": "22050", "channels": 2, "bit_rate": "64000""#),
            container: .flv, fileName: "a.flv", aacEncoder: "aac_at"
        )
        XCTAssertEqual(aac.encoding, .copy)
        XCTAssertEqual(aac.target, ImportAudioConverter.Target(channels: 2, sampleRate: 22_050, bitRate: 64_000))

        let surround = try FFmpegAudioConverter.plan(
            for: try report(stream: #""codec_name": "aac", "sample_rate": "48000", "channels": 6, "bit_rate": "384000""#),
            container: .matroska, fileName: "a.mkv", aacEncoder: "aac"
        )
        XCTAssertEqual(surround.encoding, .aac(encoder: "aac"))
        XCTAssertEqual(surround.target.channels, 2)
        XCTAssertEqual(surround.sourceChannels, 6)

        for (stream, depth) in [
            (#""codec_name": "flac", "sample_rate": "22050", "channels": 1, "bits_per_raw_sample": "16""#, 16),
            (#""codec_name": "flac", "sample_rate": "48000", "channels": 2, "bits_per_raw_sample": "24""#, 24),
            (#""codec_name": "wmalossless", "sample_rate": "44100", "channels": 2"#, 24),
            // WMA Lossless and RealAudio Lossless give their depth only by their decoders' sample format.
            (#""codec_name": "wmalossless", "sample_rate": "44100", "channels": 2, "sample_fmt": "s16p", "bits_per_sample": 0, "bits_per_raw_sample": "N/A""#, 16),
            (#""codec_name": "ralf", "sample_rate": "44100", "channels": 2, "sample_fmt": "s16p""#, 16),
            (#""codec_name": "pcm_f32le", "sample_rate": "48000", "channels": 2, "bits_per_sample": 32"#, 24),
            (#""codec_name": "pcm_s32le", "sample_rate": "48000", "channels": 2, "bits_per_sample": 32"#, 32),
        ] {
            let lossless = try FFmpegAudioConverter.plan(for: try report(stream: stream), container: .matroska, fileName: "a.mka", aacEncoder: "aac_at")
            XCTAssertEqual(lossless.encoding, .appleLossless, stream)
            XCTAssertEqual(lossless.target.appleLosslessBitDepth, depth, stream)
            XCTAssertNil(lossless.target.bitRate, stream)
        }

        let unknownRate = try FFmpegAudioConverter.plan(
            for: try report(stream: #""codec_name": "opus", "sample_rate": "48000", "channels": 1"#, format: #""format_name": "matroska,webm", "bit_rate": "1000000""#),
            container: .matroska, fileName: "a.webm", aacEncoder: "aac_at"
        )
        let opusInfo = ImportAudioConverter.SourceInfo(
            sampleRate: 48_000, channels: 1, duration: 0, formatID: "opus", bitsPerSample: nil, isLossless: false
        )
        // A file of sound alone lends its rate to its one stream.
        XCTAssertEqual(unknownRate.target, ImportAudioConverter.target(for: opusInfo, averageBitRate: 1_000_000))
        XCTAssertNil(unknownRate.duration)
        let noRateAtAll = try FFmpegAudioConverter.plan(
            for: try report(stream: #""codec_name": "opus", "sample_rate": "48000", "channels": 1"#),
            container: .matroska, fileName: "a.webm", aacEncoder: "aac_at"
        )
        XCTAssertEqual(noRateAtAll.target, ImportAudioConverter.target(for: opusInfo, averageBitRate: Double(AudioRenderSettings.bitRatePerChannel)))
    }

    /// A decoder's whole-number sample formats tell their depth (8 or 16
    /// bits, planar or not); the others do not: 32 bits may hold 24, and
    /// floating point holds no count of bits.
    func testTheSampleFormatsThatTellADepth() {
        let depths = ["u8", "u8p", "s16", "s16p", "s32", "s32p", "flt", "fltp", "dbl", "s64", ""].map {
            "\($0): \(FFprobeReport.bits(ofSampleFormat: $0).map(String.init) ?? "none")"
        }
        XCTAssertEqual(depths, ["u8: 8", "u8p: 8", "s16: 16", "s16p: 16", "s32: none", "s32p: none", "flt: none", "fltp: none",
                                "dbl: none", "s64: none", ": none"])
        XCTAssertNil(FFprobeReport.bits(ofSampleFormat: nil))
    }

    /// The codecs that keep every bit of their source become Apple
    /// Lossless; the rest, A-law and μ-law PCM among them, become AAC.
    func testWhichCodecsAreLossless() {
        for codec in ["flac", "alac", "wmalossless", "ralf", "mlp", "truehd", "pcm_s16le", "pcm_s24be", "pcm_f32le", "pcm_u8"] {
            XCTAssertTrue(FFmpegAudioConverter.isLossless(codec: codec), codec)
        }
        for codec in ["wmav1", "wmav2", "wmapro", "wmavoice", "opus", "vorbis", "speex", "mp3", "aac", "ac3", "cook",
                      "musepack7", "musepack8", "pcm_alaw", "pcm_mulaw", ""] {
            XCTAssertFalse(FFmpegAudioConverter.isLossless(codec: codec), codec)
        }
    }

    // MARK: - ffmpeg's Arguments

    /// The plan for `stream` in a Matroska file, with `aac_at`.
    private func matroskaPlan(_ stream: String) throws -> FFmpegAudioConverter.Plan {
        try FFmpegAudioConverter.plan(for: try report(stream: stream), container: .matroska, fileName: "a.mkv", aacEncoder: "aac_at")
    }

    /// The input and output every test of the arguments uses, with a space
    /// and a colon in their names, which "file:" keeps from being read as a
    /// protocol.
    private let input = URL(fileURLWithPath: "/Books/Talk: One.mkv")
    private let output = URL(fileURLWithPath: "/Books/.x.audio-conversion.m4a")

    /// The arguments ffmpeg is given, word for word, for each kind of plan:
    /// the quiet options, the file protocol alone, the demuxer named before
    /// the input, the one stream with the file's chapters and tags, and the
    /// writing of an MPEG-4 audio file last.
    func testTheArgumentsOfEachPlan() throws {
        let start = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-protocol_whitelist", "file",
                     "-f", "matroska", "-i", "file:/Books/Talk: One.mkv", "-map", "0:0", "-map_chapters", "0", "-map_metadata", "0"]
        let end = ["-f", "ipod", "file:/Books/.x.audio-conversion.m4a"]

        let copy = try matroskaPlan(#""codec_name": "aac", "sample_rate": "44100", "channels": 2"#)
        XCTAssertEqual(FFmpegAudioConverter.arguments(from: input, to: output, plan: copy), start + ["-c:a", "copy"] + end)

        let opus = try matroskaPlan(#""codec_name": "opus", "sample_rate": "48000", "channels": 2, "bit_rate": "96000""#)
        let opusRate = try XCTUnwrap(opus.target.bitRate)
        XCTAssertEqual(opus.target.sampleRate, 48_000)
        XCTAssertEqual(
            FFmpegAudioConverter.arguments(from: input, to: output, plan: opus),
            start + ["-af", "asetpts=N/SR/TB", "-c:a", "aac_at", "-b:a", String(opusRate)] + end
        )

        // An odd sample rate is written at AAC's nearest family rate, and six channels as two.
        let odd = try matroskaPlan(#""codec_name": "vorbis", "sample_rate": "37800", "channels": 6, "bit_rate": "128000""#)
        let oddRate = try XCTUnwrap(odd.target.bitRate)
        XCTAssertEqual(
            FFmpegAudioConverter.arguments(from: input, to: output, plan: odd),
            start + ["-af", "asetpts=N/SR/TB", "-c:a", "aac_at", "-b:a", String(oddRate), "-ar", "48000", "-ac", "2"] + end
        )

        let flac16 = try matroskaPlan(#""codec_name": "flac", "sample_rate": "44100", "channels": 2, "bits_per_raw_sample": "16""#)
        XCTAssertEqual(
            FFmpegAudioConverter.arguments(from: input, to: output, plan: flac16),
            start + ["-af", "asetpts=N/SR/TB", "-c:a", "alac", "-sample_fmt", "s16p"] + end
        )

        let flac24 = try matroskaPlan(#""codec_name": "flac", "sample_rate": "96000", "channels": 8, "bits_per_raw_sample": "24""#)
        XCTAssertEqual(
            FFmpegAudioConverter.arguments(from: input, to: output, plan: flac24),
            start + ["-af", "asetpts=N/SR/TB", "-c:a", "alac", "-sample_fmt", "s32p", "-bits_per_raw_sample", "24", "-ac", "2"] + end
        )

        let pcm32 = try matroskaPlan(#""codec_name": "pcm_s32le", "sample_rate": "48000", "channels": 1, "bits_per_raw_sample": "32""#)
        XCTAssertEqual(
            FFmpegAudioConverter.arguments(from: input, to: output, plan: pcm32),
            start + ["-af", "asetpts=N/SR/TB", "-c:a", "alac", "-sample_fmt", "s32p"] + end
        )
    }

    /// The stream's tags the file leaves out are written as the file's own,
    /// each as one argument of key and value, after the mapping.
    func testTheStreamsTagsAreWrittenAfterTheMapping() throws {
        let plan = try FFmpegAudioConverter.plan(
            for: try report(stream: #""codec_name": "speex", "sample_rate": "16000", "channels": 1, "bit_rate": "27800", "tags": {"title": "A = B", "artist": "Speaker"}"#,
                            format: #""format_name": "ogg""#),
            container: .oggSpeex, fileName: "a.spx", aacEncoder: "aac_at"
        )
        let arguments = FFmpegAudioConverter.arguments(from: input, to: output, plan: plan)
        let mapping = try XCTUnwrap(arguments.firstIndex(of: "-map_metadata"))
        XCTAssertEqual(Array(arguments[(mapping + 2)..<(mapping + 6)]), ["-metadata", "title=A = B", "-metadata", "artist=Speaker"])
        XCTAssertEqual(Array(arguments[7..<11]), ["-f", "ogg", "-i", "file:/Books/Talk: One.mkv"])
    }

    /// ffprobe is asked for the format and the streams as JSON, of the file
    /// protocol alone, with the demuxer named.
    func testTheProbesArguments() {
        XCTAssertEqual(
            FFmpegAudioConverter.probeArguments(for: URL(fileURLWithPath: "/Books/x.wma"), as: .asf),
            ["-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file", "-f", "asf",
             "-print_format", "json", "-show_format", "-show_streams", "file:/Books/x.wma"]
        )
    }

    /// Apple's AAC encoder is found in ffmpeg's list by its name, the second
    /// word of its line, and not by a description that mentions it.
    func testAppleAACEncoderIsFoundInTheList() {
        let homebrew = """
        Encoders:
         A....D aac                  AAC (Advanced Audio Coding)
         A..... aac_at               aac (AudioToolbox) (codec aac)
         A....D alac                 ALAC (Apple Lossless Audio Codec)
        """
        XCTAssertTrue(FFmpegAudioConverter.listsAppleAACEncoder(homebrew))
        XCTAssertFalse(FFmpegAudioConverter.listsAppleAACEncoder(" A....D aac   AAC, as aac_at would be\n"))
        XCTAssertFalse(FFmpegAudioConverter.listsAppleAACEncoder(""))
    }

    /// A source that does not say its length is taken, for its limits only,
    /// to last as long as 6 kbit/s would make it, at most a year.
    func testAnUnknownLengthIsAssumedLongForTheLimits() {
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: 6_000), 8)
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: -5), 0)
        XCTAssertEqual(FFmpegAudioConverter.assumedDuration(ofBytes: .max), FFprobeReport.maximumDuration)
    }

    // MARK: - Finding ffprobe

    /// ffprobe is looked for beside the ffmpeg found first, then in the
    /// other folders and along the PATH; none found is nil.
    func testFFprobeIsFoundBesideFFmpegFirst() throws {
        let folder = try makeSandboxDirectory("FFprobeLocate")
        let beside = folder.appendingPathComponent("brew", isDirectory: true)
        let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
        for directory in [beside, elsewhere] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["ffmpeg", "ffprobe"] {
                let file = directory.appendingPathComponent(name)
                try Data("#!/bin/sh\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        let ffmpeg = FFmpeg(executable: beside.appendingPathComponent("ffmpeg"))
        let other = elsewhere.appendingPathComponent("ffprobe").path
        XCTAssertEqual(ffmpeg.probe(in: [other], environment: [:])?.path, beside.appendingPathComponent("ffprobe").path)
        let alone = FFmpeg(executable: folder.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(alone.probe(in: [other], environment: [:])?.path, other)
        XCTAssertEqual(alone.probe(in: [], environment: ["PATH": "/nowhere:\(elsewhere.path)"])?.path, other)
        XCTAssertNil(alone.probe(in: [], environment: ["PATH": "/nowhere"]))
    }

    // MARK: - The Words

    /// Every extension ffmpeg converts has a name people say, and Speex in
    /// Ogg is Speex whatever its name.
    func testEveryFormatHasItsName() {
        let names = FFmpegAudioConverter.extensions.sorted().map { "\($0): \(FFmpegImportWording.kindName(forExtension: $0) ?? "none")" }
        XCTAssertEqual(names, [
            "asf: Windows Media", "avi: AVI video", "flv: Flash video", "mka: Matroska", "mkv: Matroska", "mp+: Musepack",
            "mpc: Musepack", "mpp: Musepack", "ra: RealMedia", "rm: RealMedia", "rmvb: RealMedia", "spx: Speex",
            "weba: WebM", "webm: WebM", "wma: WMA", "wmv: WMV video",
        ])
        XCTAssertNil(FFmpegImportWording.kindName(forExtension: "mp3"))
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.ogg"), container: .oggSpeex), "Speex")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.WMA"), container: .asf), "WMA")
        XCTAssertEqual(FFmpegImportWording.kindName(of: URL(fileURLWithPath: "/a/Talk.xyz"), container: .asf), "XYZ")
    }

    /// The sentences a listener hears, word for word: they name the format,
    /// say what to install and how, and hold no symbol VoiceOver would
    /// spell out.
    func testTheSentencesAListenerHears() {
        XCTAssertEqual(
            FFmpegAudioConverter.Failure.ffmpegMissing(kind: "WMA").localizedDescription,
            "To import WMA files, TextMouth needs ffmpeg, a free program that isn't installed on this Mac. "
                + "Install it with Homebrew by typing brew install ffmpeg in Terminal, then import the file again."
        )
        XCTAssertEqual(
            FFmpegAudioConverter.Failure.ffprobeMissing(kind: "WebM").localizedDescription,
            "To import WebM files, TextMouth needs ffprobe, which comes with ffmpeg but isn't installed on this Mac. "
                + "Install ffmpeg with Homebrew by typing brew install ffmpeg in Terminal, then import the file again."
        )
        XCTAssertEqual(FFmpegAudioConverter.Failure.copyProtected.localizedDescription, "TextMouth cannot open copy-protected files.")
        XCTAssertEqual(
            FFmpegAudioConverter.Failure.notRecognized(fileName: "Lecture.wma", kind: "WMA").localizedDescription,
            "TextMouth can't read “Lecture.wma” as WMA. It may be damaged, or named for another format."
        )
        XCTAssertEqual(FFmpegAudioConverter.Failure.noSound(fileName: "Clip.mkv").localizedDescription, "“Clip.mkv” holds no sound to import.")
        XCTAssertEqual(
            ImportAudioConverter.Failure.checkFailed(fileName: "Talk.webm", reason: FFmpegImportWording.convertedFileIsSilent)
                .localizedDescription,
            "The audio converted from Talk.webm failed its check: it lasts no time."
        )
        for sentence in [FFmpegImportWording.ffmpegMissing(kind: "WMA"), FFmpegImportWording.ffprobeMissing(kind: "WMA")] {
            XCTAssertNil(sentence.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}<>/\\|*#@~`^:;")), sentence)
        }
    }
}
