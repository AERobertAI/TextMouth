import Foundation

// MARK: - Timed Text (FMT23, FMT25)

/// A kind of timed-text file: a transcript whose every stretch of text is
/// timed. TextMouth reads one to give an audiobook a transcript without
/// transcribing it, on any macOS: a file found beside a track at import or
/// chosen with Attach Transcript… (FMT23), or a podcast episode's own
/// transcript, fetched with the episode (FMT25). It writes WebVTT and
/// SubRip when a transcript is exported in either.
///
/// The raw values are kept in transcript.json and bookInfo.json, where a
/// transcript records where it came from, so they never change.
enum TimedTextFormat: String, Codable, CaseIterable, Sendable {
    /// WebVTT (W3C), the format Podcasting 2.0 recommends first: a `WEBVTT`
    /// line, then cues timed `MM:SS.mmm` or `HH:MM:SS.mmm`, whose voice tags
    /// (`<v Ana>`) name who speaks.
    case webVTT = "webvtt"
    /// SubRip: numbered cues timed `HH:MM:SS,mmm`, a format with no
    /// standard, in whatever text encoding its maker used.
    case subRip = "srt"
    /// Podcasting 2.0's JSON transcript, version 1.0.0: segments of a
    /// speaker, a start, an end, and a body, the times in seconds.
    case podcastJSON = "podcast-json"

    /// The extension a file of the format takes, lowercased, without its dot.
    var fileExtension: String {
        switch self {
        case .webVTT: return "vtt"
        case .subRip: return "srt"
        case .podcastJSON: return "json"
        }
    }

    /// The format's name, as the screen shows it and VoiceOver speaks it.
    var name: String {
        switch self {
        case .webVTT: return "WebVTT"
        case .subRip: return "SubRip"
        case .podcastJSON: return "Podcasting 2.0 JSON"
        }
    }

    /// The formats a transcript file is taken in by its name alone (one the
    /// listener chooses, or one found beside a track), in the order a
    /// track's files are preferred: WebVTT, then SubRip (the charter's
    /// decision 3). A JSON file is never taken for a transcript by its name:
    /// too many other files end in .json.
    static let cueFileFormats: [TimedTextFormat] = [.webVTT, .subRip]

    /// The format `cueFileFormats` names by `fileExtension`, in any letter
    /// case ("vtt", "SRT"); nil for any other extension.
    static func cueFileFormat(forExtension fileExtension: String) -> TimedTextFormat? {
        let lowered = fileExtension.lowercased()
        return cueFileFormats.first { $0.fileExtension == lowered }
    }
}

// MARK: - A Cue

/// One cue of a timed-text file, as a reader found it: a stretch of the
/// audio, and the words spoken in it.
struct TimedTextCue: Equatable, Sendable {
    /// When the cue begins, in milliseconds from the start of its audio.
    var startMilliseconds: Int
    /// When the cue ends, in milliseconds from the start of its audio: never
    /// before `startMilliseconds`.
    var endMilliseconds: Int
    /// The cue's words as plain text on one line: its markup removed, its
    /// character references decoded, each run of white space one space, and
    /// none at either end. Never blank: a reader passes over a cue whose text
    /// would be.
    var text: String
    /// Who speaks the cue, when the file says: a WebVTT voice (`<v Ana>`), a
    /// JSON segment's speaker. Nil when it names nobody; never blank.
    var voice: String? = nil
    /// The cue's timed words, each where it lies in `text`, in UTF-16 units,
    /// and when it was spoken, when the file times words, as a Podcasting
    /// 2.0 transcript of one word per segment does; empty when it times none.
    /// They lie in order inside `text` and inside the cue's time, as a
    /// transcript's words must (`Transcript.validationFailure()`).
    var words: [TranscriptWord] = []

    /// `raw` as a cue's text (`text`): each run of white space (spaces,
    /// tabs, line breaks, no-break spaces, and the rest of Unicode's white
    /// space) one space, and none at either end. Every reader finishes a
    /// cue's text with it, so cues read from any format are spaced alike.
    static func plainText(_ raw: some StringProtocol) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - A File Read

/// What a timed-text file holds, once read.
struct TimedTextDocument: Equatable, Sendable {
    /// The file's format.
    var format: TimedTextFormat
    /// Its cues, in the order they begin; cues that begin together keep the
    /// order the file gives them.
    var cues: [TimedTextCue]
    /// How many of the file's cues were passed over as unusable: a time that
    /// does not read or lies past `Transcript.maximumMilliseconds`, an end
    /// before its start, or text that is nothing but markup and white space.
    var skippedCueCount: Int = 0

    /// The cues as a transcript's sentences (`TranscriptSentence`), in order:
    /// each cue's text, times, and words, with its voice named before its
    /// text ("Ana: First tone.") whenever that voice is not the one named
    /// last, so a listener hears who speaks each time the speaker changes,
    /// and not again for each cue the same voice speaks. A cue without a
    /// voice names nobody, and leaves the voice named last as it was. A
    /// named cue's words move along by the name's length, so each still lies
    /// over its own characters.
    var sentences: [TranscriptSentence] {
        var lastNamed: String?
        return cues.map { cue in
            guard let voice = cue.voice, voice != lastNamed else {
                return TranscriptSentence(
                    text: cue.text,
                    startMilliseconds: cue.startMilliseconds,
                    endMilliseconds: cue.endMilliseconds,
                    words: cue.words
                )
            }
            lastNamed = voice
            let name = voice + ": "
            let shift = name.utf16.count
            return TranscriptSentence(
                text: name + cue.text,
                startMilliseconds: cue.startMilliseconds,
                endMilliseconds: cue.endMilliseconds,
                words: cue.words.map { word in
                    var moved = word
                    moved.characterOffset += shift
                    return moved
                }
            )
        }
    }
}

// MARK: - Why a File Is Not Read

/// Why a timed-text file could not be read as a transcript, in words a
/// listener understands, the same on screen, in VoiceOver, and in braille.
/// A reason never quotes the file's text, which is the book's.
enum TimedTextError: LocalizedError, Equatable {
    /// The file is larger than TextMouth reads as a transcript: the limit,
    /// in bytes.
    case tooLarge(byteLimit: Int)
    /// The file is not text, or not a file of the format: a WebVTT file
    /// without its `WEBVTT` line, a JSON transcript that is not JSON or has
    /// no list of segments.
    case notTimedText(TimedTextFormat)
    /// A Podcasting 2.0 file of a version TextMouth does not read, as the
    /// file gives its version.
    case unsupportedVersion(TimedTextFormat, String)
    /// The file holds no cue whose times and text TextMouth can use.
    case noCues(TimedTextFormat)
    /// The file holds more cues than TextMouth reads: the limit.
    case tooManyCues(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let byteLimit):
            return "The file is larger than the \(byteLimit / 1_048_576) MB TextMouth reads as a transcript."
        case .notTimedText(let format):
            return "The file isn't a \(format.name) transcript TextMouth can read."
        case .unsupportedVersion(let format, let version):
            return "The file is a \(format.name) transcript of version \(version), which TextMouth doesn't read."
        case .noCues(let format):
            return "The \(format.name) file holds no timed text TextMouth can use."
        case .tooManyCues(let limit):
            return "The file holds more than \(limit.formatted()) timed passages, more than TextMouth reads."
        }
    }
}

// MARK: - Bounds

/// How much of a timed-text file TextMouth reads, and how far past the end
/// of the audio its times may run (FMT23, FMT25). A transcript from outside
/// is third-party data: every size and count read from it is bounded.
enum TimedTextLimits {
    /// The largest transcript file read from this Mac, one the listener
    /// chose or one found beside a track: 20 MB. SubRip captions take about
    /// 80 bytes for every 3 seconds, so 20 MB holds some 200 hours, twice
    /// the longest audio file a transcript may time
    /// (`Transcript.maximumMilliseconds`).
    static let localFileBytes = 20 * 1_048_576

    /// The largest transcript fetched with a podcast episode: 5 MB (the
    /// charter's decision 5). A Podcasting 2.0 JSON transcript of one word
    /// per segment, the largest kind, takes about 70 bytes a word, some
    /// 750 KB for an hour of speech, so 5 MB holds six hours or more; a
    /// server sending more is sending something else.
    static let podcastTranscriptBytes = 5 * 1_048_576

    /// The largest chapters file fetched with a podcast episode: 1 MB (the
    /// charter's decision 5). A chapter with its picture and link takes a
    /// few hundred bytes, so 1 MB holds thousands of chapters.
    static let podcastChaptersBytes = 1_048_576

    /// The most cues a file may hold: 250,000, more than 20 MB of SubRip
    /// holds, and three cues a second for a whole day of audio.
    static let maximumCues = 250_000

    /// How far past the end of its audio a transcript's last cue may end,
    /// or a chapters file's last chapter begin, in milliseconds, and still
    /// be taken for that audio's: 5 seconds (the charter's decision 6).
    ///
    /// Cue and chapter times are rounded; an encoder adds or trims up to a
    /// second of padding at either end; and the length a variable-bit-rate
    /// MP3 reports can differ from its decoded length by a second or two. An
    /// advertisement a host inserts into each download, the reason an
    /// episode's transcript can describe another edition of it, lasts 15
    /// seconds or more. So a file running up to 5 seconds past the end
    /// differs from the audio only by rounding and padding, and one running
    /// further was made for other audio, and is refused.
    static let pastTheEndMarginMilliseconds = 5_000
}
