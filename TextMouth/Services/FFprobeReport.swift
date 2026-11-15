import Foundation

/// What ffprobe says a file of a format only ffmpeg reads holds (FMT31,
/// FMT32): its streams, its length, and its tags, read from the JSON that
/// `ffprobe -print_format json -show_format -show_streams` prints. ffprobe
/// runs as a watched child process (`FFmpegAudioConverter.Tool`), so a
/// hostile file can cost a child, never the app; this type only reads the
/// text it printed, and believes no number that is not plausible: a header
/// can claim any length or rate.
struct FFprobeReport: Equatable, Sendable {
    /// One stream of the file, as ffprobe describes it.
    struct Stream: Equatable, Sendable {
        /// The stream's index in the file, which `-map 0:<index>` names.
        let index: Int
        /// "audio", "video", "subtitle", "data", or "attachment".
        let codecType: String
        /// ffmpeg's name of its codec: "wmav2", "opus", "flac", "aac", ...
        let codecName: String
        /// Its sample rate in hertz; nil when unknown or implausible.
        let sampleRate: Double?
        /// Its channels; nil when unknown or implausible.
        let channels: Int?
        /// Its bit rate in bits a second: ffprobe's, else the `BPS` tag
        /// mkvmerge writes; nil when unknown or implausible.
        let bitRate: Int?
        /// How long it lasts in seconds: ffprobe's, else Matroska's
        /// `DURATION` tag; nil when unknown or implausible.
        let duration: TimeInterval?
        /// The bits of each sample its codec keeps, for a lossless one:
        /// ffprobe's count, else what its decoder's sample format holds
        /// (`bits(ofSampleFormat:)`); nil when unknown.
        let bitsPerSample: Int?
        /// Whether the file marks it as the stream to play.
        let isDefault: Bool
        /// Whether it is a picture attached to the file (a cover), not a
        /// stream of its own.
        let isAttachedPicture: Bool
        /// Its tags, each key in lowercase.
        let tags: [String: String]

        /// Whether this is a sound stream TextMouth can convert: audio, with
        /// a plausible sample rate and number of channels.
        var isUsableAudio: Bool {
            codecType == "audio" && !isAttachedPicture && sampleRate != nil && channels != nil
        }
    }

    /// ffmpeg's name of the demuxer that read the file ("asf",
    /// "matroska,webm", ...).
    let formatName: String
    /// How long the file lasts in seconds; nil when unknown or implausible.
    let duration: TimeInterval?
    /// The whole file's bit rate in bits a second; nil when unknown.
    let bitRate: Int?
    /// The file's own tags, each key in lowercase.
    let tags: [String: String]
    /// Its streams, in the file's order.
    let streams: [Stream]

    // MARK: - Plausibility

    /// The longest length believed: a year, as for every other format
    /// (`AudioFileInfo.maximumPlausibleDuration`).
    static let maximumDuration: TimeInterval = AudioFileInfo.maximumPlausibleDuration

    /// The highest sample rate believed, in hertz: 768 kHz, the highest any
    /// recording format writes.
    static let maximumSampleRate: Double = 768_000

    /// The most channels believed: 64.
    static let maximumChannels = 64

    /// The highest bit rate believed, in bits a second: 100 Mbit/s.
    static let maximumBitRate = 100_000_000

    // MARK: - Reading the JSON

    /// The report in `json`, ffprobe's output; nil when it is not JSON of
    /// the shape ffprobe prints or names no stream at all. Numbers may be
    /// written as numbers or as strings, as ffprobe writes some of each.
    init?(json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]], !streams.isEmpty else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]
        formatName = format["format_name"] as? String ?? ""
        duration = Self.plausibleDuration(Self.number(format["duration"]))
        bitRate = Self.plausibleBitRate(Self.number(format["bit_rate"]))
        tags = Self.lowercasedTags(format["tags"])
        self.streams = streams.enumerated().map { position, stream in Self.stream(from: stream, position: position) }
    }

    /// The stream ffprobe describes in `object`, the `position`th of the
    /// file's (its index when ffprobe gives none).
    private static func stream(from object: [String: Any], position: Int) -> Stream {
        let tags = lowercasedTags(object["tags"])
        let disposition = object["disposition"] as? [String: Any] ?? [:]
        // The first count of bits ffprobe gives that is one (it writes 0 or
        // "N/A" for none), else what the decoder's sample format holds.
        let counted = [number(object["bits_per_raw_sample"]), number(object["bits_per_sample"])]
            .compactMap { $0 }
            .first { $0 >= 1 && $0 <= 64 }
            .map { Int($0) }
        // mkvmerge names its statistics "BPS" and "DURATION", or, in its
        // older versions, with "-eng" after them.
        let taggedBitRate = number(tags["bps"] ?? tags["bps-eng"])
        let taggedDuration = matroskaDuration(tags["duration"] ?? tags["duration-eng"])
        return Stream(
            // A stream's index is small; one that is not is no index.
            index: number(object["index"]).flatMap { $0 >= 0 && $0 < 100_000 ? Int($0) : nil } ?? position,
            codecType: object["codec_type"] as? String ?? "",
            codecName: object["codec_name"] as? String ?? "",
            sampleRate: number(object["sample_rate"]).flatMap { $0 > 0 && $0 <= maximumSampleRate ? $0 : nil },
            channels: number(object["channels"]).flatMap { $0 >= 1 && $0 <= Double(maximumChannels) ? Int($0) : nil },
            // ffprobe's own figure when it is believed, else the tag's: it
            // writes 0 for a length or rate it could not work out.
            bitRate: plausibleBitRate(number(object["bit_rate"])) ?? plausibleBitRate(taggedBitRate),
            duration: plausibleDuration(number(object["duration"])) ?? plausibleDuration(taggedDuration),
            bitsPerSample: counted ?? bits(ofSampleFormat: object["sample_fmt"] as? String),
            isDefault: number(disposition["default"]) == 1,
            isAttachedPicture: number(disposition["attached_pic"]) == 1,
            tags: tags
        )
    }

    /// The number `value` holds, written as a JSON number or as a string
    /// ("44100", "3.000000"); nil for anything else, and for one that is not
    /// finite.
    static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let number as NSNumber: parsed = number.doubleValue
        case let text as String: parsed = Double(text.trimmingCharacters(in: .whitespaces))
        default: parsed = nil
        }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
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

    /// The bits of a sample that a decoder's whole-number sample format
    /// holds, planar or not: 8 for "u8", 16 for "s16". WMA Lossless and
    /// RealAudio Lossless say their depth only this way. Nil for any other
    /// format, whose depth it does not tell ("s32" may hold 24 bits, and
    /// floating point holds none).
    static func bits(ofSampleFormat format: String?) -> Int? {
        switch format {
        case "u8", "u8p": return 8
        case "s16", "s16p": return 16
        default: return nil
        }
    }

    /// The seconds of a Matroska `DURATION` tag, "HH:MM:SS.fraction" (as
    /// "00:00:03.008000000"); nil when `text` is not of that form.
    static func matroskaDuration(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: ":"), parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    /// The tags in `value`, ffprobe's object of strings, each key in
    /// lowercase (Matroska writes "ARTIST", ASF "artist"); a value that is not
    /// a string is left out, and of two keys that differ only in case the
    /// first in key order is kept.
    private static func lowercasedTags(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var tags: [String: String] = [:]
        for key in object.keys.sorted() {
            guard let text = object[key] as? String else { continue }
            let lowered = key.lowercased()
            if tags[lowered] == nil { tags[lowered] = text }
        }
        return tags
    }

    // MARK: - Choosing the Sound

    /// The sound stream a book is made of (FMT32): the first the file marks
    /// as its default, else its first; only streams TextMouth can convert
    /// are considered (`Stream.isUsableAudio`). Nil when the file holds none,
    /// as a video without sound does.
    var chosenAudio: Stream? {
        let usable = streams.filter(\.isUsableAudio)
        return usable.first(where: \.isDefault) ?? usable.first
    }

    /// Whether the file holds a stream other than sound, a picture track or
    /// subtitles: its bit rate is then not its sound's.
    var holdsMoreThanSound: Bool {
        streams.contains { $0.codecType != "audio" && !$0.isAttachedPicture }
    }

    /// How long `stream` lasts: its own length, else the file's; nil when
    /// neither is known.
    func duration(of stream: Stream) -> TimeInterval? {
        stream.duration ?? duration
    }

    /// The bit rate of `stream`: its own, else, for a file of sound alone,
    /// the file's shared among its sound streams; nil when neither is known.
    func bitRate(of stream: Stream) -> Int? {
        if let own = stream.bitRate { return own }
        guard !holdsMoreThanSound, let whole = bitRate else { return nil }
        return whole / max(streams.filter { $0.codecType == "audio" }.count, 1)
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

    /// The tags a book of `stream`, in a file of `container`, takes: the
    /// file's own, then, in Ogg alone (`streamTagsAreTheFiles(in:)`), the
    /// stream's for any key the file leaves out. The keys are lowercase.
    func tags(of stream: Stream, in container: FFmpegContainer) -> [String: String] {
        guard Self.streamTagsAreTheFiles(in: container) else { return tags }
        return tags.merging(stream.tags) { own, _ in own }
    }

    /// The keys of the tags carried into the converted file that ffmpeg's
    /// MPEG-4 writer turns into the tags a player reads: title, artist,
    /// album, its artist, the date, the genre, the composer, and a comment.
    static let carriedTagKeys = ["title", "artist", "album", "album_artist", "date", "genre", "composer", "comment"]

    /// The tags of `carriedTagKeys` that the file, of `container`, leaves to
    /// `stream`, which the conversion writes itself (`-metadata`), since
    /// `-map_metadata 0` copies only the file's own; in key order. Empty when
    /// the file names them all, the stream names none of them, or the file
    /// is no Ogg (`streamTagsAreTheFiles(in:)`).
    func streamTagsToCarry(of stream: Stream, in container: FFmpegContainer) -> [(key: String, value: String)] {
        guard Self.streamTagsAreTheFiles(in: container) else { return [] }
        return Self.carriedTagKeys.compactMap { key in
            guard tags[key] == nil, let value = stream.tags[key], !value.isEmpty else { return nil }
            return (key, value)
        }
    }
}
