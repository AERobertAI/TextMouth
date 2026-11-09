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
    /// The voice that speaks last in the cue, when another voice than
    /// `voice` takes over inside it (`<v Ana>Hi.<v Ben>Hello.` ends in Ben's
    /// voice, the text naming him where his tag stood). Nil when the cue
    /// ends in `voice`, or has none. A transcript needs it to name the next
    /// cue's speaker whenever that is not the one who spoke last
    /// (`TimedTextDocument.sentences`); never blank.
    var lastVoice: String? = nil
    /// The cue's timed words, each where it lies in `text`, in UTF-16 units,
    /// and when it was spoken, when the file times words, as a Podcasting
    /// 2.0 transcript of one word per segment does; empty when it times none.
    /// They lie in order inside `text` and inside the cue's time, as a
    /// transcript's words must (`Transcript.validationFailure()`).
    var words: [TranscriptWord] = []
    /// Whether the file's text for the cue was longer than TextMouth keeps
    /// (`TimedTextLimits.maximumCueCharacters`), so `text` is its beginning,
    /// cut where a sentence ends or, failing that, between words. A listener
    /// is told how many cues were cut (`TimedTextDocument.cutCueCount`).
    var isCutShort = false

    /// `raw` as a cue's text (`text`): each run of white space (spaces,
    /// tabs, line breaks, no-break spaces, and the rest of Unicode's white
    /// space) one space, and none at either end; and every control character
    /// that is not white space (NUL, BEL, ESC, DEL, and the C1 controls)
    /// left out, as the SubRip writer and a chapter's title leave them out.
    /// Every reader finishes a cue's text, and a speaker's name, with it, so
    /// cues read from any format are spaced alike, and no third-party file
    /// puts a control character into a book's text, its speech, or braille.
    static func plainText(_ raw: some StringProtocol) -> String {
        finishedText(of: raw, characterLimit: .max).text
    }

    /// `raw` as a speaker's name: finished as `plainText(_:)` finishes it and
    /// kept to `TimedTextLimits.maximumVoiceNameCharacters`. Every reader
    /// finishes a voice name with it.
    static func voiceName(_ raw: some StringProtocol) -> String {
        finishedText(of: raw, characterLimit: TimedTextLimits.maximumVoiceNameCharacters).text
    }

    /// `raw` finished as `plainText(_:)` finishes it, but kept to at most
    /// `characterLimit` characters, so one cue, or one name, of a hostile
    /// file cannot be a book's single sentence (or be copied into every cue
    /// after it, as a speaker's name is). Past the limit the reading of
    /// `raw` stops, so the cost is that of the limit, not of the file, and
    /// the text is cut back to where a sentence ends in its second half,
    /// failing that to the last space, failing that at the limit itself.
    /// - Returns: The finished text, and whether it was cut.
    static func finishedText(of raw: some StringProtocol, characterLimit: Int) -> (text: String, wasCut: Bool) {
        // Built character by character, a space put in only when a word
        // follows: the same text as splitting at white space and joining,
        // but without an array holding a substring (32 bytes) for each
        // word, which for a 20 MB cue of one-letter words was some 320 MB.
        var plain = ""
        var count = 0
        var followsWhiteSpace = false
        for character in raw {
            if character.isWhitespace {
                // White space at the start puts nothing in; elsewhere it
                // waits to see whether a word follows it.
                followsWhiteSpace = !plain.isEmpty
            } else if isControl(character) {
                // Left out as if it were never there: "a\u{7}b" is "ab".
                continue
            } else {
                // A word that would pass the limit is where the text stops.
                if count + (followsWhiteSpace ? 2 : 1) > characterLimit {
                    return (cutBack(plain), true)
                }
                if followsWhiteSpace {
                    plain.append(" ")
                    count += 1
                    followsWhiteSpace = false
                }
                plain.append(character)
                count += 1
            }
        }
        return (plain, false)
    }

    /// `text`, which was cut at its end, cut back to the end of the last
    /// sentence in its second half, else to its last space, else as it is, so
    /// a cue seldom ends in half a word.
    private static func cutBack(_ text: String) -> String {
        let characters = Array(text)
        var lastSpace: Int?
        var index = characters.count - 1
        while index >= characters.count / 2 {
            if characters[index] == " " {
                lastSpace = lastSpace ?? index
                if endsSentence(characters[..<index]) {
                    return String(characters[..<index])
                }
            }
            index -= 1
        }
        return lastSpace.map { String(characters[..<$0]) } ?? text
    }

    /// The marks that end a sentence when a word ends with one.
    private static let sentenceEndingMarks: Set<Character> = [".", "?", "!", "…"]

    /// The marks that may follow a sentence's end: quotation marks, straight
    /// and curly, and closing brackets, as in `said.”` or `(see above.)`.
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]"]

    /// Whether `text` ends a sentence: whether its last character, after any
    /// closing quotation marks and brackets, is ".", "?", "!", or "…". Both
    /// the Podcasting 2.0 reader, gathering words into sentences, and the cut
    /// of a cue too long to keep use it.
    static func endsSentence(_ text: some BidirectionalCollection<Character>) -> Bool {
        guard let last = text.reversed().first(where: { !closingMarks.contains($0) }) else {
            return false
        }
        return sentenceEndingMarks.contains(last)
    }

    /// Whether `character` is a control character (Unicode's Cc). A control
    /// character is always a character of its own, never joined to the
    /// marks around it, so its first scalar says.
    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.generalCategory == .control
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

    /// How many of the cues were kept only in part, their text longer than
    /// TextMouth keeps (`TimedTextCue.isCutShort`).
    var cutCueCount: Int {
        cues.reduce(0) { $0 + ($1.isCutShort ? 1 : 0) }
    }

    /// The cues as a transcript's sentences (`TranscriptSentence`), in order:
    /// each cue's text, times, and words, with its voice named before its
    /// text ("Ana: First tone.") whenever that voice is not the one named
    /// last, so a listener hears who speaks each time the speaker changes,
    /// and not again for each cue the same voice speaks. A cue without a
    /// voice names nobody, and leaves the voice named last as it was. A
    /// named cue's words move along by the name's length, so each still lies
    /// over its own characters. A cue in which another voice takes over
    /// (`TimedTextCue.lastVoice`) leaves that voice as the one named last, so
    /// the next cue in the first voice names it again, and one in the second
    /// does not.
    var sentences: [TranscriptSentence] {
        var lastNamed: String?
        return cues.map { cue in
            // The voice speaking at the cue's end is the one named last
            // once the cue is done, whether or not its start was named.
            defer { lastNamed = cue.lastVoice ?? cue.voice ?? lastNamed }
            guard let voice = cue.voice, voice != lastNamed else {
                return TranscriptSentence(
                    text: cue.text,
                    startMilliseconds: cue.startMilliseconds,
                    endMilliseconds: cue.endMilliseconds,
                    words: cue.words
                )
            }
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

    /// The most characters one cue's text keeps: 10,000, some 1,700 words,
    /// which is ten times a long caption and more than any sentence a
    /// speaker says. Past it the text is cut (`TimedTextCue.isCutShort`), so
    /// a file that is one 20 MB cue cannot make one sentence and paragraph
    /// of that length in a book, which neither the reader's layout, nor
    /// VoiceOver, nor braille is made for.
    static let maximumCueCharacters = 10_000

    /// The most characters a speaker's name keeps: 100. A name is put before
    /// the text each time the speaker changes, so a name of megabytes would
    /// be copied into every cue after it.
    static let maximumVoiceNameCharacters = 100

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
