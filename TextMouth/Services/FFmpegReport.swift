import Foundation
private import TextMouthFFmpegProtocol

/// What TextMouth's FFmpeg session says a file of a format only FFmpeg reads
/// holds (FMT31, FMT32, FMT50): the sound stream it chose, how long it lasts,
/// its tags, and its chapters, read from the session's INFO, TAG, STAG, and
/// CHAP records (`FFmpegHelperStream`). On the Mac the session runs in the
/// bundled helper, TextMouthFFmpeg, a watched child process, so a hostile file
/// can cost a child, never the app; this type only reads what it wrote, and
/// believes no number that is not plausible: a header can claim any length or
/// rate.
struct FFmpegReport: Equatable, Sendable {
    /// How the PCM records hold each sample (INFO's sample_format).
    enum SampleFormat: String, Equatable, Sendable {
        /// 16-bit signed whole numbers of up to 16 bits.
        case s16
        /// 32-bit signed whole numbers of `bits` bits.
        case s32
        /// 32-bit floating point, from -1 to 1.
        case f32
    }

    /// One chapter of the file.
    struct Chapter: Equatable, Sendable {
        /// Where it starts, in seconds.
        let start: TimeInterval
        /// Where it ends, in seconds, when the file says.
        let end: TimeInterval?
        /// Its title; empty when it has none.
        let title: String
    }

    /// FFmpeg's name of the demuxer that read the file ("asf",
    /// "matroska,webm", ...).
    let formatName: String
    /// FFmpeg's name of the chosen stream's codec: "wmav2", "opus", "flac",
    /// "aac", ...
    let codecName: String
    /// The chosen stream's index in the file.
    let streamIndex: Int
    /// How many streams the file holds, and how many of them are sound.
    let streamCount: Int
    let audioStreamCount: Int
    /// Whether the file holds a stream other than sound and a cover picture,
    /// such as a picture track or subtitles: its bit rate is then not its
    /// sound's.
    let holdsMoreThanSound: Bool
    /// Whether the file marks the chosen stream as the one to play.
    let isDefault: Bool
    /// Its sample rate in hertz; nil when implausible.
    let sampleRate: Double?
    /// Its channels; nil when implausible.
    let channels: Int?
    /// Which loudspeaker each channel is, as a WAVE channel mask; nil when
    /// unknown.
    let channelMask: UInt32?
    /// How the PCM records hold its samples; nil when the session named a
    /// form this reader does not know.
    let sampleFormat: SampleFormat?
    /// The bits of each sample in the PCM records.
    let bits: Int
    /// How long the stream lasts, in seconds: its own, else Matroska's
    /// `DURATION` tag; nil when unknown or implausible.
    let streamDuration: TimeInterval?
    /// How long the file lasts, in seconds; nil when unknown or implausible.
    let formatDuration: TimeInterval?
    /// The stream's bit rate in bits a second: its own, else the `BPS` tag
    /// mkvmerge writes; nil when unknown or implausible.
    let streamBitRate: Int?
    /// The whole file's bit rate in bits a second; nil when unknown.
    let formatBitRate: Int?
    /// The file's own tags, each key in lowercase (`FFmpegReport.tags(from:)`).
    let tags: [String: String]
    /// The chosen stream's tags, each key in lowercase.
    let streamTags: [String: String]
    /// The file's chapters, in its order.
    let chapters: [Chapter]

    // MARK: - Plausibility

    /// The longest length believed: a year, as for every other format
    /// (`AudioFileInfo.maximumPlausibleDuration`).
    static let maximumDuration: TimeInterval = AudioFileInfo.maximumPlausibleDuration

    /// The highest sample rate believed, in hertz: 768 kHz, the highest any
    /// recording format writes (the protocol's TMFF_MAX_SAMPLE_RATE, which
    /// the session chooses no stream beyond).
    static let maximumSampleRate = Double(TMFF_MAX_SAMPLE_RATE)

    /// The most channels believed: 64 (the protocol's TMFF_MAX_CHANNELS).
    static let maximumChannels = Int(TMFF_MAX_CHANNELS)

    /// The highest bit rate believed, in bits a second: 100 Mbit/s.
    static let maximumBitRate = 100_000_000

    /// The most bytes of a tag's value or a chapter's title kept: 4 KB, as
    /// the session cuts them (the protocol's TMFF_MAX_TAG_VALUE_BYTES, the
    /// TODO's FU-FFMPEG item). A longer one, which no session of this
    /// protocol writes, is cut here too.
    static let maximumTagBytes = Int(TMFF_MAX_TAG_VALUE_BYTES)

    // MARK: - Reading the Records

    /// The report of the INFO record `info`'s lines and the tags and
    /// chapters that came with it. Numbers that are missing or implausible
    /// are nil (or 0); nil when INFO names no codec, or no sample rate or
    /// channels at all, which no session writes.
    init?(info: [String: String], fileTags: [(String, String)], streamTags: [(String, String)], chapters: [Chapter]) {
        guard let codec = info["codec"], !codec.isEmpty, info["sample_rate"] != nil, info["channels"] != nil else {
            return nil
        }
        let lowercasedStreamTags = Self.tags(from: streamTags)
        formatName = info["format"] ?? ""
        codecName = codec
        streamIndex = Self.whole(info["stream"]) ?? 0
        streamCount = Self.whole(info["streams"]) ?? 1
        audioStreamCount = Self.whole(info["audio_streams"]) ?? 1
        holdsMoreThanSound = info["more_than_sound"] == "1"
        isDefault = info["default"] == "1"
        sampleRate = Self.number(info["sample_rate"]).flatMap { $0 > 0 && $0 <= Self.maximumSampleRate ? $0 : nil }
        channels = Self.whole(info["channels"]).flatMap { $0 >= 1 && $0 <= Self.maximumChannels ? $0 : nil }
        channelMask = Self.whole(info["channel_mask"]).flatMap { $0 > 0 && $0 <= Int(UInt32.max) ? UInt32($0) : nil }
        sampleFormat = info["sample_format"].flatMap(SampleFormat.init(rawValue:))
        bits = Self.whole(info["bits"]).flatMap { $0 >= 1 && $0 <= 32 ? $0 : nil } ?? 32
        // mkvmerge names its statistics "BPS" and "DURATION", or, in its
        // older versions, with "-eng" after them.
        let taggedDuration = Self.matroskaDuration(lowercasedStreamTags["duration"] ?? lowercasedStreamTags["duration-eng"])
        let taggedBitRate = Self.number(lowercasedStreamTags["bps"] ?? lowercasedStreamTags["bps-eng"])
        streamDuration = Self.plausibleDuration(Self.number(info["duration"])) ?? Self.plausibleDuration(taggedDuration)
        formatDuration = Self.plausibleDuration(Self.number(info["format_duration"]))
        streamBitRate = Self.plausibleBitRate(Self.number(info["bit_rate"])) ?? Self.plausibleBitRate(taggedBitRate)
        formatBitRate = Self.plausibleBitRate(Self.number(info["format_bit_rate"]))
        tags = Self.tags(from: fileTags)
        self.streamTags = lowercasedStreamTags
        self.chapters = chapters
    }

    /// The number `text` holds ("44100", "3.000000"); nil for anything
    /// else, and for one that is not finite.
    static func number(_ text: String?) -> Double? {
        guard let text, let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite else { return nil }
        return parsed
    }

    /// The whole number `text` holds; nil for anything else, or one past
    /// what an `Int` holds.
    private static func whole(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// A length in seconds that is believed: above zero and at most
    /// `maximumDuration`.
    private static func plausibleDuration(_ seconds: Double?) -> TimeInterval? {
        seconds.flatMap { $0 > 0 && $0 <= maximumDuration ? $0 : nil }
    }

    /// A bit rate that is believed: above zero and at most `maximumBitRate`.
    private static func plausibleBitRate(_ bits: Double?) -> Int? {
        bits.flatMap { $0 > 0 && $0 <= Double(maximumBitRate) ? Int($0) : nil }
    }

    /// The seconds of a Matroska `DURATION` tag, "HH:MM:SS.fraction" (as
    /// "00:00:03.008000000"); nil when `text` is not of that form.
    static func matroskaDuration(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: ":"), parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    /// The tags `pairs` (key, value) as the report keeps them: each key in
    /// lowercase (Matroska writes "ARTIST", ASF "artist"); of two keys that
    /// differ only in case, the first in key order kept; a value cut to
    /// `maximumTagBytes` (`cut(_:toBytes:)`); and a value that is empty, or
    /// holds the replacement character U+FFFD, left out as missing (the
    /// TODO's FU-FFMPEG item): it is text that was not UTF-8, and a book
    /// named by it would read as noise.
    static func tags(from pairs: [(String, String)]) -> [String: String] {
        var tags: [String: String] = [:]
        for (key, value) in pairs.sorted(by: { $0.0 < $1.0 }) {
            let lowered = key.lowercased()
            guard tags[lowered] == nil, !value.isEmpty, !value.unicodeScalars.contains("\u{FFFD}") else { continue }
            tags[lowered] = cut(value, toBytes: maximumTagBytes)
        }
        return tags
    }

    /// `text` cut to at most `limit` bytes of UTF-8, at a character's
    /// boundary.
    static func cut(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= limit else { break }
            kept.append(character)
            bytes += size
        }
        return kept
    }

    // MARK: - The Sound

    /// Whether the chosen stream is sound TextMouth can convert: a plausible
    /// sample rate and number of channels, and samples in a form it reads.
    var isUsableSound: Bool {
        sampleRate != nil && channels != nil && sampleFormat != nil
    }

    /// How long the sound lasts: the stream's own length, else the file's;
    /// nil when neither is known.
    var duration: TimeInterval? {
        streamDuration ?? formatDuration
    }

    /// The bit rate of the sound: its own, else, for a file of sound alone,
    /// the file's shared among its sound streams; nil when neither is known.
    var bitRate: Int? {
        if let own = streamBitRate { return own }
        guard !holdsMoreThanSound, let whole = formatBitRate else { return nil }
        return whole / max(audioStreamCount, 1)
    }

    /// The bits of each sample its codec keeps, for a whole-number form; nil
    /// for floating point, which keeps no depth of whole bits.
    var bitsPerSample: Int? {
        sampleFormat == .f32 ? nil : bits
    }

    // MARK: - Tags

    /// Whether the tags of a stream in `container` stand for the file's own
    /// where its format leaves a key out: only in Ogg, which keeps its
    /// comments on the stream (a Speex file's title is there). Matroska and
    /// AVI keep a track's name there ("Stereo", "Soundtrack"), which is no
    /// book's title (review9 finding 3).
    static func streamTagsAreTheFiles(in container: FFmpegContainer) -> Bool {
        container == .ogg || container == .oggSpeex
    }

    /// The tags a book of this file, of `container`, takes: the file's own,
    /// then, in Ogg alone (`streamTagsAreTheFiles(in:)`), the stream's for
    /// any key the file leaves out. The keys are lowercase.
    func tags(in container: FFmpegContainer) -> [String: String] {
        guard Self.streamTagsAreTheFiles(in: container) else { return tags }
        return tags.merging(streamTags) { own, _ in own }
    }

    /// The title, artist, album, genre, and date of a book of this file, of
    /// `container`, from `tags(in:)`: ASF's Author and Matroska's ARTIST both
    /// come through as the artist, and RealMedia's author keeps its name
    /// (review9 finding 5), so the artist is the first of artist, author, and
    /// album_artist; the date is date, else year. An .m4a converted from it
    /// carries these (`OwnAudioConverter.metadataItems(for:)`), and the import
    /// names a book of one file by them (`AudioPlaybackService.extractFullMetadata`).
    func bookTags(in container: FFmpegContainer) -> OwnAudioTags {
        let tags = tags(in: container)
        var book = OwnAudioTags()
        book.title = tags["title"] ?? ""
        book.artist = tags["artist"] ?? tags["author"] ?? tags["album_artist"] ?? ""
        book.album = tags["album"] ?? ""
        book.genre = tags["genre"] ?? ""
        book.date = tags["date"] ?? tags["year"] ?? ""
        return book
    }

    /// The chapters as a conversion keeps them (`ImportAudioConverter.keepChapters`):
    /// each start that is a finite number from zero on, in order, titled by
    /// its own title.
    var chapterMarks: [NeroChapterReader.Chapter] {
        chapters
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
            .map { NeroChapterReader.Chapter(title: $0.title, start: $0.start) }
    }
}
