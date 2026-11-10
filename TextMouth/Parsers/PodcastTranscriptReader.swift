import Foundation

// MARK: - A Podcast's Own Transcript (FMT25)

/// Reads a podcast episode's own transcript, in Podcasting 2.0's JSON format
/// (version 1.0.0, podcasting2.org), into the timed text every transcript
/// reader gives (`TimedTextDocument`):
///
///     {"version": "1.0.0", "segments": [
///         {"speaker": "Ana", "startTime": 0.0, "endTime": 0.9, "body": "First tone."}
///     ]}
///
/// A segment's times are in seconds. Many feeds give one word per segment,
/// so a run of one speaker's words is gathered into a sentence: one cue,
/// which keeps each word's own time. A segment of several words is a cue of
/// its own.
///
/// The file is third-party data. A segment whose times or text do not read
/// is passed over and counted, never guessed at; the cues are capped; and no
/// link or other field of the file is followed or kept. Nothing here logs,
/// so no transcript's words can reach the log.
enum PodcastTranscriptReader {
    /// The longest silence, in milliseconds, between two words of one
    /// sentence: a word that starts this long or longer after the word
    /// before it ends begins another sentence.
    static let wordGapMilliseconds = 1_000

    /// The most words one sentence gathers: a sentence of this many ends
    /// there, so a feed whose words never end a sentence still gives cues
    /// short enough to move among.
    static let maximumWordsPerSentence = 60

    /// The transcript `data` holds: its usable segments in the order they
    /// begin, each run of one speaker's words gathered into a sentence.
    ///
    /// - Parameters:
    ///   - data: the file's bytes, already bounded by whoever fetched or
    ///     opened it (`TimedTextLimits`).
    ///   - maximumCues: the most cues the file may give; a test lowers it.
    /// - Throws: `TimedTextError.notTimedText(.podcastJSON)` when `data` is
    ///   not JSON, holds no object at its top, or has no list of segments;
    ///   `.unsupportedVersion` for a major version other than 1;
    ///   `.tooManyCues` as soon as the cues pass `maximumCues`; and
    ///   `.noCues` when no segment can be used.
    static func read(_ data: Data, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument {
        guard let file = FeedJSON.object(in: data) else {
            throw TimedTextError.notTimedText(.podcastJSON)
        }
        if let version = PodcastingJSON.unsupportedVersion(of: file) {
            throw TimedTextError.unsupportedVersion(.podcastJSON, version)
        }
        guard let elements = file["segments"] as? [Any] else {
            throw TimedTextError.notTimedText(.podcastJSON)
        }
        // Every element that does not make a usable segment is counted as
        // passed over; the rest are put in order before any is gathered.
        let segments = elements.compactMap(Segment.init(element:))
        let ordered = PodcastingJSON.sortedByStart(segments, start: \.start)
        let cues = try gatherCues(from: ordered, maximumCues: maximumCues)
        guard !cues.isEmpty else {
            throw TimedTextError.noCues(.podcastJSON)
        }
        return TimedTextDocument(format: .podcastJSON, cues: cues, skippedCueCount: elements.count - segments.count)
    }

    // MARK: - Segments

    /// One usable segment of the file: its times, its text, and who speaks it.
    private struct Segment {
        /// When the segment begins, in milliseconds.
        let start: Int
        /// When it ends, in milliseconds: never before `start`.
        let end: Int
        /// Its text on one line (`TimedTextCue.plainText`), kept to
        /// `TimedTextLimits.maximumCueCharacters`: never empty.
        let body: String
        /// Whether `body` is the beginning of a longer text, cut
        /// (`TimedTextCue.isCutShort`).
        let isCutShort: Bool
        /// Who speaks it; nil when the file names nobody. Never blank.
        let voice: String?

        /// The segment `element`, one element of the file's list, gives; nil
        /// when it is unusable: not an object, a time that does not read or
        /// lies past `Transcript.maximumMilliseconds`, an end before its
        /// start, or a body that is not text or holds nothing but white
        /// space. A speaker that is not text, or is blank, names nobody.
        init?(element: Any) {
            guard let fields = element as? [String: Any],
                  let start = PodcastingJSON.milliseconds(fields["startTime"]),
                  let end = PodcastingJSON.milliseconds(fields["endTime"]),
                  end >= start,
                  let (body, isCutShort) = PodcastingJSON.cueText(fields["body"]),
                  !body.isEmpty
            else {
                return nil
            }
            self.start = start
            self.end = end
            self.body = body
            self.isCutShort = isCutShort
            let speaker = PodcastingJSON.voiceName(fields["speaker"])
            voice = speaker?.isEmpty == false ? speaker : nil
        }

        /// Whether the segment is a single word, as a feed that times every
        /// word gives: text with no space in it. Its body is finished, so a
        /// space is the only white space it can hold.
        var isWord: Bool {
            !body.contains(" ")
        }

        /// The segment as a cue of its own, whose words are not timed.
        var cue: TimedTextCue {
            TimedTextCue(startMilliseconds: start, endMilliseconds: end, text: body, voice: voice, isCutShort: isCutShort)
        }
    }

    // MARK: - Words Into Sentences

    /// The cues `segments`, in the order they begin, make: each run of one
    /// speaker's words gathered into a sentence (`Sentence.takes(_:)` says
    /// how long a run may be), and each segment of several words a cue of
    /// its own, which ends any sentence being gathered.
    /// - Throws: `TimedTextError.tooManyCues` as soon as the cues pass
    ///   `maximumCues`, so a huge file is refused without being gathered whole.
    private static func gatherCues(from segments: [Segment], maximumCues: Int) throws -> [TimedTextCue] {
        var cues: [TimedTextCue] = []
        var sentence: Sentence?

        /// Adds `cue` to the cues, refusing the file when they would pass
        /// `maximumCues`.
        func add(_ cue: TimedTextCue) throws {
            guard cues.count < maximumCues else {
                throw TimedTextError.tooManyCues(limit: maximumCues)
            }
            cues.append(cue)
        }

        for segment in segments {
            // A word the sentence being gathered takes joins it.
            if segment.isWord, sentence?.takes(segment) == true {
                sentence?.add(segment)
                continue
            }
            // Anything else ends that sentence. A word begins the next one;
            // a segment of several words is a cue of its own.
            if let finished = sentence {
                try add(finished.cue)
            }
            if segment.isWord {
                sentence = Sentence(startingWith: segment)
            } else {
                sentence = nil
                try add(segment.cue)
            }
        }
        if let finished = sentence {
            try add(finished.cue)
        }
        return cues
    }

    /// One speaker's words, in order, being gathered into a sentence: a cue
    /// whose text is the words joined by single spaces, and whose `words`
    /// keep each word's place in that text and its own time.
    ///
    /// Its words always satisfy `Transcript.validationFailure()`: they come
    /// in the order they begin, the sentence begins where its first word
    /// does and ends at the latest end among them, and each lies in the
    /// text after the one before it.
    private struct Sentence {
        /// Who speaks every word of the sentence; nil when nobody is named.
        let voice: String?
        /// When the first word begins, in milliseconds.
        let start: Int
        /// The latest end among the words, in milliseconds: a word may end
        /// after the one following it begins.
        private var end: Int
        /// The words joined by single spaces.
        private var text = ""
        /// `text`'s length in UTF-16 units, kept as words are added, so a
        /// word's offset is known without counting the text again.
        private var textLength = 0
        /// Each word, where it lies in `text`, and when it was spoken.
        private var words: [TranscriptWord] = []
        /// When the word added last ends, in milliseconds.
        private var lastWordEnd: Int
        /// Whether the word added last ends a sentence
        /// (`TimedTextCue.endsSentence(_:)`).
        private var isEnded = false
        /// Whether any word added was itself cut short
        /// (`TimedTextCue.isCutShort`).
        private var isCutShort = false

        /// A sentence of `word` alone, so far.
        init(startingWith word: Segment) {
            voice = word.voice
            start = word.start
            end = word.end
            lastWordEnd = word.end
            add(word)
        }

        /// Whether `word`, the next word in order, joins the sentence: while
        /// the sentence has not ended and holds fewer than
        /// `maximumWordsPerSentence` words, a word of the same speaker (no
        /// speaker counting as the same as no speaker) joins it when it
        /// starts less than `wordGapMilliseconds` after the word before it
        /// ends. A word that starts before that one ends joins it too. A
        /// word that would take the text past
        /// `TimedTextLimits.maximumCueCharacters` begins the next sentence
        /// instead: words as long as the limit allows are no words at all,
        /// and sixty of them must not make a cue of sixty times the limit.
        func takes(_ word: Segment) -> Bool {
            !isEnded
                && words.count < PodcastTranscriptReader.maximumWordsPerSentence
                && textLength + 1 + word.body.utf16.count <= TimedTextLimits.maximumCueCharacters
                && word.voice == voice
                && word.start - lastWordEnd < PodcastTranscriptReader.wordGapMilliseconds
        }

        /// Adds `word` at the end of the sentence, after a space.
        mutating func add(_ word: Segment) {
            if !words.isEmpty {
                text += " "
                textLength += 1
            }
            let length = word.body.utf16.count
            words.append(TranscriptWord(
                characterOffset: textLength,
                characterCount: length,
                startMilliseconds: word.start,
                endMilliseconds: word.end,
                confidence: nil
            ))
            text += word.body
            textLength += length
            end = max(end, word.end)
            lastWordEnd = word.end
            isEnded = TimedTextCue.endsSentence(word.body)
            isCutShort = isCutShort || word.isCutShort
        }

        /// The sentence as a cue, with its words timed.
        var cue: TimedTextCue {
            TimedTextCue(
                startMilliseconds: start, endMilliseconds: end, text: text, voice: voice, words: words,
                isCutShort: isCutShort
            )
        }
    }
}

// MARK: - What Podcasting 2.0's Two Files Share

/// What both of Podcasting 2.0's JSON files, a transcript
/// (`PodcastTranscriptReader`) and a chapters file (`PodcastChapters`), are
/// read with alike. Each reader takes its file's object with
/// `FeedJSON.object(in:)`, reads its version, times, and text here, and
/// throws its own errors.
enum PodcastingJSON {
    /// How many characters of a version TextMouth does not read are kept in
    /// the error that names it: the version is the file's own text, and the
    /// error is logged.
    static let versionCharacterLimit = 20

    /// The version `file` gives when TextMouth does not read it, cut to its
    /// first `versionCharacterLimit` characters; nil when TextMouth reads
    /// it. The part of a version before its first "." is its major version,
    /// and both of Podcasting 2.0's files are of major version 1 ("1.0.0",
    /// "1.2.0", or "1" alone); a later one may have changed what the fields
    /// mean. A file that gives no version, or one that is not text, is read
    /// as version 1.
    static func unsupportedVersion(of file: [String: Any]) -> String? {
        guard let version = file["version"] as? String else {
            return nil
        }
        let major = version.prefix { $0 != "." }
        return major == "1" ? nil : String(version.prefix(versionCharacterLimit))
    }

    /// The time `value` gives, a number of seconds, as a whole number of
    /// milliseconds (`Transcript.milliseconds(_:)`): a JSON number, or text
    /// holding one ("2.5"), that is finite, not negative, and no later than
    /// `Transcript.maximumMilliseconds`. Nil for anything else: no value,
    /// true or false, text that is no number, "nan", "inf", or a time past
    /// the maximum.
    static func milliseconds(_ value: Any?) -> Int? {
        guard let seconds = FeedJSON.number(value), seconds >= 0 else {
            return nil
        }
        let milliseconds = Transcript.milliseconds(seconds)
        return milliseconds <= Transcript.maximumMilliseconds ? milliseconds : nil
    }

    /// `value` finished as a cue's text is (`TimedTextCue.plainText`) when it
    /// is text, which may leave it empty; nil when it is not text. Used for a
    /// chapter's title, which no limit holds to.
    static func plainText(_ value: Any?) -> String? {
        (value as? String).map { TimedTextCue.plainText($0) }
    }

    /// `value` as a cue's text, finished and kept to
    /// `TimedTextLimits.maximumCueCharacters` (`TimedTextCue.finishedText`),
    /// with whether it was cut; nil when it is not text.
    static func cueText(_ value: Any?) -> (text: String, wasCut: Bool)? {
        (value as? String).map {
            TimedTextCue.finishedText(of: $0, characterLimit: TimedTextLimits.maximumCueCharacters)
        }
    }

    /// `value` as a speaker's name (`TimedTextCue.voiceName`) when it is
    /// text, which may leave it empty; nil when it is not text.
    static func voiceName(_ value: Any?) -> String? {
        (value as? String).map { TimedTextCue.voiceName($0) }
    }

    /// `items` sorted by when each begins, `start`, those that begin together
    /// keeping the order the file gives them. Ties are broken by each item's
    /// place in the file, as `NeroChapterReader` breaks them, so the order
    /// never rests on how the standard library's sort treats equal items.
    static func sortedByStart<Item>(_ items: [Item], start: (Item) -> Int) -> [Item] {
        items.enumerated()
            .sorted { first, second in
                let (firstStart, secondStart) = (start(first.element), start(second.element))
                return firstStart != secondStart ? firstStart < secondStart : first.offset < second.offset
            }
            .map(\.element)
    }
}
