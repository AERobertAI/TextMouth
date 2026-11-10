import Foundation

// MARK: - The Transcript

/// A transcript of an audiobook's narration (FR05): what the speech
/// recognizer heard in each of the book's audio files, sentence by sentence,
/// each sentence with its words and when each was spoken.
///
/// TextMouth keeps it in the book's package as transcript.json
/// (`TranscriptStore`), where it syncs with the library as content.md does,
/// and writes the book's transcript text from it. It is a record, not a
/// cache: transcribing takes minutes and the recognizer's model changes, so
/// nothing rebuilds it but transcribing the book again. Each audio file's
/// fingerprint is kept with it, so a file edited or replaced since it was
/// transcribed is noticed and its transcript is no longer trusted.
///
/// Every time is a whole number of milliseconds from the start of its own
/// file. The recognizer times words in steps of 60 milliseconds, which
/// milliseconds keep exactly, and integers keep every value exact through
/// JSON and the file compact: about 8,000 words an hour of narration.
struct Transcript: Codable, Equatable, Sendable {
    /// The layout of transcript.json this version of TextMouth writes and
    /// reads. A transcript of another layout, as a later TextMouth on
    /// another Mac sharing the library could write, is left as it is and
    /// not read (`TranscriptStore.Lookup.unsupportedVersion`).
    static let currentVersion = 1

    /// The latest moment a sentence or word may be placed at in its file, in
    /// milliseconds: 100 hours, longer than any audio file. A time beyond it
    /// in a transcript.json can only be damage, and is refused so that no sum
    /// of times can overflow.
    static let maximumMilliseconds = 360_000_000

    /// The layout this transcript was written in (`currentVersion`).
    var version: Int
    /// The language the recognizer transcribed in, as a BCP 47 identifier
    /// such as "en-US": the locale its model was chosen for.
    var locale: String
    /// The recognizer and its model.
    var model: TranscriptSpeechModel
    /// The build of TextMouth that transcribed the book.
    var app: TranscriptAppBuild
    /// When the transcription finished.
    var createdAt: Date
    /// Each of the book's audio files, in the order the book plays them.
    var files: [TranscriptFile]
    /// When the user last edited the transcript's text in their own editor
    /// (Edit Text, `TranscriptEditing`), in whole seconds; nil for a
    /// transcript as the recognizer made it. transcript.json leaves it out
    /// until then, so an earlier TextMouth reads an edited transcript as
    /// any other. Transcribing again replaces an edited transcript only
    /// after the Transcribe Audio sheet has said so.
    var editedAt: Date? = nil
    /// When the transcript was last cleaned up by rule (Clean Up Transcript,
    /// `TranscriptCleanup`), with which rules and how many corrections; nil
    /// for a transcript never cleaned up. transcript.json leaves it out
    /// until then, as it leaves out `editedAt`.
    var cleanedUp: TranscriptCleanupNote? = nil
    /// Where the transcript came from when TextMouth's recognizer did not
    /// make it: a timed-text file attached or found at import, or a
    /// podcast's own transcript (FMT23, FMT25). Nil for a transcript
    /// recognition made. transcript.json leaves it out until then, so a
    /// recognized transcript is written byte for byte as before, and an
    /// earlier TextMouth reads a transcript with a source as any other
    /// (JSONDecoder passes over keys it does not know).
    var source: TranscriptSource? = nil

    /// What a book's record notes about this transcript (`BookState.transcript`).
    var note: TranscriptNote {
        TranscriptNote(version: version, locale: locale, createdAt: createdAt, source: source)
    }

    /// The file whose path, relative to the book's audio folder, is `path`,
    /// or nil when the transcript holds none.
    func file(at path: String) -> TranscriptFile? {
        files.first { $0.path == path }
    }

    /// How many words the transcript holds, every file's sentences counted
    /// (`TranscriptSentence.wordCount`), as a finished transcription
    /// announces it.
    var wordCount: Int {
        files.reduce(0) { total, file in
            file.sentences.reduce(total) { $0 + $1.wordCount }
        }
    }
}

/// The recognizer that made a transcript, and what the system reported
/// about its model, so a transcript made by an older model can be told
/// apart from one made since the system updated it.
struct TranscriptSpeechModel: Codable, Equatable, Sendable {
    /// The recognizer: "SpeechTranscriber", macOS 26's module of
    /// SpeechAnalyzer for long-form narration.
    var engine: String
    /// What the system's asset inventory reported for the locale's model
    /// when the transcription began: "installed", "supported", "downloading",
    /// or "unsupported" (`AssetInventory.Status`). The model of an installed
    /// locale can be reported as "supported" while an update to it waits.
    var assetStatus: String
    /// The version of macOS whose model it was, as the system words it,
    /// such as "Version 26.3.1 (Build 25D2128)": the system installs and
    /// updates the model, and reports no version of its own for it.
    var systemVersion: String
}

/// The build of TextMouth that made a transcript (`BuildIdentity`).
struct TranscriptAppBuild: Codable, Equatable, Sendable {
    /// The marketing version, such as "1.0".
    var version: String
    /// The build number.
    var build: String
    /// The Git commit the build was made from.
    var commit: String

    /// The build of TextMouth that is running.
    static var current: TranscriptAppBuild {
        let identity = BuildIdentity.current
        return TranscriptAppBuild(version: identity.version, build: identity.buildNumber, commit: identity.gitCommit)
    }
}

/// One audio file of a transcribed book: the file as it was when it was
/// transcribed, and the sentences heard in it, in the order they were
/// spoken.
struct TranscriptFile: Codable, Equatable, Sendable {
    /// The file's path relative to the book's audio folder, as the book's
    /// content index names it ("03.mp3", "Disc 2/03.mp3"), or, for a book
    /// of one audio file, that file's name.
    var path: String
    /// The file's size, modification time, and digest when it was
    /// transcribed. A file whose size or contents differ now has changed
    /// since, and its transcript no longer describes it.
    var fingerprint: FileFingerprint
    /// How long the file plays, in milliseconds, as measured when it was
    /// transcribed.
    var durationMilliseconds: Int
    /// The sentences heard in the file, in the order they were spoken.
    var sentences: [TranscriptSentence]
}

/// One sentence of a transcript: its text, when it was spoken in its file,
/// and its words.
struct TranscriptSentence: Codable, Equatable, Sendable {
    /// The sentence as the recognizer wrote it, punctuated, on one line,
    /// with single spaces between its words and none at either end.
    var text: String
    /// When the sentence begins in its file, in milliseconds. The
    /// recognizer counts a pause as part of the word after it, so a
    /// sentence begins where the one before it ended.
    var startMilliseconds: Int
    /// When the sentence ends in its file, in milliseconds.
    var endMilliseconds: Int
    /// The sentence's words, in order, each where it lies in `text` and
    /// when it was spoken. Empty when the recognizer timed none.
    var words: [TranscriptWord]

    /// How many words the sentence holds: its timed words, or, when none
    /// were timed, the runs of its text between spaces.
    var wordCount: Int {
        words.isEmpty ? text.split(whereSeparator: \.isWhitespace).count : words.count
    }

    /// Gives the sentence `text` in place of its own, as an edit in the
    /// user's editor (`TranscriptEditing`) or a cleanup
    /// (`TranscriptCleanup`) rewrites it: the sentence keeps its time in the
    /// audio, and its words' timings, which no longer fit the new text, go.
    /// The text it has already changes nothing.
    mutating func rewrite(as text: String) {
        guard text != self.text else { return }
        self.text = text
        words = []
    }
}

/// One word of a transcript's sentence: where it lies in the sentence's text
/// and when it was spoken.
///
/// transcript.json writes a word as an array of numbers rather than an
/// object, since words are what a transcript holds most of: the UTF-16
/// offset and length of the word in its sentence's text, its start and end
/// in milliseconds, and, when the recognizer gave one, its confidence, as in
/// `[5, 6, 840, 1560, 0.784]`.
struct TranscriptWord: Equatable, Sendable {
    /// Where the word begins in its sentence's text, in UTF-16 units.
    var characterOffset: Int
    /// The word's length in UTF-16 units: the recognizer's word with any
    /// punctuation it attached ("Porter."), without spaces.
    var characterCount: Int
    /// When the word begins in its file, in milliseconds. A pause before
    /// the word is counted as part of it.
    var startMilliseconds: Int
    /// When the word ends in its file, in milliseconds.
    var endMilliseconds: Int
    /// How sure the recognizer was of the word, from 0 to 1, to three
    /// decimal places; nil when it gave no confidence.
    var confidence: Double?
}

extension TranscriptWord: Codable {
    /// Reads a word as transcript.json writes it: four whole numbers, then
    /// the confidence when there is one.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        characterOffset = try container.decode(Int.self)
        characterCount = try container.decode(Int.self)
        startMilliseconds = try container.decode(Int.self)
        endMilliseconds = try container.decode(Int.self)
        // No fifth number, or a null in its place, means no confidence.
        if container.isAtEnd {
            confidence = nil
        } else if try container.decodeNil() {
            confidence = nil
        } else {
            confidence = try container.decode(Double.self)
        }
    }

    /// Writes a word as an array: its place in the sentence, its times,
    /// and its confidence when it has one.
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(characterOffset)
        try container.encode(characterCount)
        try container.encode(startMilliseconds)
        try container.encode(endMilliseconds)
        if let confidence {
            try container.encode(confidence)
        }
    }
}

// MARK: - Times

extension Transcript {
    /// `seconds` as a whole number of milliseconds, to the nearest: a time
    /// the recognizer reports in 60 ms steps (0.059937 seconds is one such
    /// step, carrying the rounding of its arithmetic) becomes exactly 60.
    /// A time that is not a finite number, or is negative, becomes 0.
    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        // Far beyond any recording, and far below Int's limit.
        return Int((min(seconds, 1e12) * 1_000).rounded())
    }

    /// `milliseconds` as seconds.
    static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1_000
    }

    /// A confidence the recognizer reported, kept to three decimal places,
    /// or nil for one that is not a number from 0 to 1.
    static func confidence(_ reported: Double?) -> Double? {
        guard let reported, reported.isFinite, (0...1).contains(reported) else { return nil }
        return (reported * 1_000).rounded() / 1_000
    }
}

// MARK: - What a Book's Record Notes

/// What a transcribed audiobook's record, bookInfo.json, notes about its
/// transcript (`BookState.transcript`), so that knowing whether a book has
/// one, and which, never means reading transcript.json or the content
/// index: the transcript's layout version, its language, when it was
/// made, and, for one TextMouth's recognizer did not make, where it came
/// from.
struct TranscriptNote: Codable, Hashable, Sendable {
    /// The layout version of the book's transcript.json.
    var version: Int
    /// The language the book was transcribed in (`Transcript.locale`).
    var locale: String
    /// When the transcription finished (`Transcript.createdAt`).
    var createdAt: Date
    /// Where the transcript came from (`Transcript.source`); nil for one
    /// recognition made, and then left out of the record, as before.
    var source: TranscriptSource? = nil
}

// MARK: - Where a Transcript Came From

/// Where a transcript that TextMouth's recognizer did not make came from
/// (FMT23, FMT25): how it reached the book, the format of the file it was
/// read from, and that file's name. transcript.json keeps it with the
/// transcript (`Transcript.source`), and the book's record notes it
/// (`TranscriptNote.source`), so the Transcribe Audio sheet can say where
/// the book's transcript came from before transcribing replaces it.
///
/// The origin and the format are kept as the strings written, not as
/// enumerations: a value a later TextMouth writes, such as an origin this
/// one does not know, then neither fails the whole transcript.json (an
/// unknown case would throw as it decodes, and a transcript.json that
/// cannot be decoded is set aside unread) nor is lost when this TextMouth
/// saves the transcript again, as an edit or a cleanup does.
/// `knownOrigin` and `knownFormat` read them as this TextMouth knows them.
struct TranscriptSource: Codable, Hashable, Sendable {
    /// How a transcript reached its book. The raw values are kept in
    /// transcript.json and bookInfo.json, so they never change.
    enum Origin: String, Sendable {
        /// The listener attached it with Book > Attach Transcript….
        case attached
        /// A file found beside the audio when the book was imported.
        case imported
        /// The podcast's own transcript, downloaded with the episode.
        case podcast
    }

    /// How the transcript reached its book: an `Origin`'s raw value, or a
    /// later TextMouth's, kept as it was written.
    var origin: String
    /// The format of the file it was read from: a `TimedTextFormat`'s raw
    /// value, or a later TextMouth's, kept as it was written.
    var format: String
    /// The name of the file it was read from, when one file was read, as
    /// "lecture.vtt"; nil when several were, or when it has no name worth
    /// showing. Never a path, never an address: it is shown to the
    /// listener, and kept in files that sync with the library.
    var fileName: String?
    /// The formats of every file it was read from, each once, in the order
    /// the files were read, when files of more than one format were read (a
    /// track's 01.vtt and another's 02.srt): `TimedTextFormat` raw values or
    /// a later TextMouth's. Nil when all the files were of `format`, which is
    /// then the one format of the transcript, and in every transcript an
    /// earlier TextMouth wrote, which cannot read this field and keeps
    /// `format` as the first file's.
    var formats: [String]?

    /// The source of a transcript that reached its book by `origin`, read
    /// from a file of `format` named `fileName`. A name given with folders
    /// before it keeps only its last part, so no folder of the listener's
    /// is ever kept or shown; a name of nothing but white space is no name.
    ///
    /// For a transcript read from files of several formats, `format` is the
    /// first file's and `otherFormats` are the formats of the rest; those
    /// the same as one named already are not repeated.
    init(origin: Origin, format: TimedTextFormat, fileName: String? = nil, otherFormats: [TimedTextFormat] = []) {
        self.origin = origin.rawValue
        self.format = format.rawValue
        self.fileName = fileName.flatMap(Self.lastPathComponent(of:))
        var distinct = [format]
        for other in otherFormats where !distinct.contains(other) {
            distinct.append(other)
        }
        formats = distinct.count > 1 ? distinct.map(\.rawValue) : nil
    }

    /// The origin, when it is one this TextMouth knows; nil for one a later
    /// TextMouth wrote.
    var knownOrigin: Origin? {
        Origin(rawValue: origin)
    }

    /// The format, when it is one this TextMouth knows; nil for one a later
    /// TextMouth wrote.
    var knownFormat: TimedTextFormat? {
        TimedTextFormat(rawValue: format)
    }

    /// Every format the transcript's files were of, in the order the files
    /// were read, when this TextMouth knows them all; nil when a later
    /// TextMouth wrote a format it does not know, whatever the others are.
    var knownFormats: [TimedTextFormat]? {
        let known = (formats ?? [format]).compactMap(TimedTextFormat.init(rawValue:))
        return known.count == (formats?.count ?? 1) ? known : nil
    }

    /// The last part of `name` after any slashes ("lecture.vtt" of
    /// "Talks/2026/lecture.vtt"), or nil when there is none or it is
    /// nothing but white space.
    private static func lastPathComponent(of name: String) -> String? {
        guard let last = name.split(separator: "/").last,
              !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(last)
    }
}

// MARK: - Validation

extension Transcript {
    /// Why this transcript cannot be trusted, naming the first offending
    /// field as transcript.json spells it, such as
    /// `files[2].sentences[5].endMilliseconds is 1200, before its startMilliseconds 1260`;
    /// nil when it can.
    ///
    /// Everything the book's transcript text and its timing rely on must
    /// hold: a supported layout, a language, files named once each by a
    /// path that stays inside the book's audio folder, and sentences in the
    /// order they were spoken, each with text, a start no later than its
    /// end, and words that lie inside its text and its time, in order. A
    /// reason never quotes the transcript's words, which are the book's
    /// text: a log line may carry the reason (`TranscriptStore`), and no
    /// log line holds book text (`DiagnosticLog`).
    func validationFailure() -> String? {
        if version != Self.currentVersion {
            return "version \(version) is not the supported \(Self.currentVersion)"
        }
        if locale.trimmingCharacters(in: .whitespaces).isEmpty {
            return "locale is empty"
        }
        var paths = Set<String>()
        for (number, file) in files.enumerated() {
            let field = "files[\(number)]"
            if let failure = Self.pathFailure(file.path, field: "\(field).path") {
                return failure
            }
            if !paths.insert(file.path).inserted {
                return "\(field).path names a file listed before it"
            }
            if file.durationMilliseconds < 0 {
                return "\(field).durationMilliseconds is \(file.durationMilliseconds), below 0"
            }
            if let failure = Self.sentencesFailure(file.sentences, field: field) {
                return failure
            }
        }
        return nil
    }

    /// Why `path`, a file's path relative to the book's audio folder, is
    /// unusable: empty, absolute, or climbing out of the folder with "..";
    /// nil when it is a relative path inside the folder.
    private static func pathFailure(_ path: String, field: String) -> String? {
        if path.isEmpty {
            return "\(field) is empty"
        }
        if path.hasPrefix("/") {
            return "\(field) is absolute"
        }
        if path.split(separator: "/").contains("..") {
            return "\(field) contains a \"..\" component"
        }
        return nil
    }

    /// Why `sentences`, a file's sentences, are out of order or unusable,
    /// naming the first offending sentence after `field`, the file's field.
    private static func sentencesFailure(_ sentences: [TranscriptSentence], field: String) -> String? {
        var previousStart = 0
        for (number, sentence) in sentences.enumerated() {
            let field = "\(field).sentences[\(number)]"
            if sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(field).text is blank"
            }
            if sentence.startMilliseconds < previousStart {
                return "\(field).startMilliseconds is \(sentence.startMilliseconds), "
                    + "before the previous sentence's \(previousStart)"
            }
            if sentence.endMilliseconds < sentence.startMilliseconds {
                return "\(field).endMilliseconds is \(sentence.endMilliseconds), "
                    + "before its startMilliseconds \(sentence.startMilliseconds)"
            }
            // The order is checked, so no time is below 0; each also lies
            // no later than the maximum. The words, which lie inside their
            // sentence's time, are held to it by `wordsFailure`.
            let maximum = Self.maximumMilliseconds
            if !(0...maximum).contains(sentence.startMilliseconds) {
                return "\(field).startMilliseconds is \(sentence.startMilliseconds), outside 0 through \(maximum)"
            }
            if !(0...maximum).contains(sentence.endMilliseconds) {
                return "\(field).endMilliseconds is \(sentence.endMilliseconds), outside 0 through \(maximum)"
            }
            if let failure = wordsFailure(sentence.words, of: sentence, field: field) {
                return failure
            }
            previousStart = sentence.startMilliseconds
        }
        return nil
    }

    /// Why `words`, the words of `sentence`, are unusable: a word that is
    /// empty, lies outside the sentence's text or time, or comes before the
    /// word ahead of it; nil when every word lies in order inside both.
    private static func wordsFailure(
        _ words: [TranscriptWord],
        of sentence: TranscriptSentence,
        field: String
    ) -> String? {
        let textLength = sentence.text.utf16.count
        var previousEnd = 0
        var previousStart = sentence.startMilliseconds
        for (number, word) in words.enumerated() {
            let field = "\(field).words[\(number)]"
            if word.characterCount <= 0 {
                return "\(field) is \(word.characterCount) characters long"
            }
            // Ranges are formed only from offsets known to be in bounds.
            if word.characterOffset < previousEnd || word.characterOffset > textLength - word.characterCount {
                // The two numbers came from a file: they are worded, never added.
                return "\(field) starts at character \(word.characterOffset) and is \(word.characterCount) long, "
                    + "outside \(previousEnd) through \(textLength)"
            }
            if word.startMilliseconds < previousStart || word.endMilliseconds < word.startMilliseconds
                || word.endMilliseconds > sentence.endMilliseconds {
                return "\(field) runs from \(word.startMilliseconds) to \(word.endMilliseconds) ms, outside "
                    + "\(previousStart) through \(sentence.endMilliseconds)"
            }
            if let confidence = word.confidence, !(confidence.isFinite && (0...1).contains(confidence)) {
                return "\(field) has a confidence of \(confidence), outside 0 through 1"
            }
            previousEnd = word.characterOffset + word.characterCount
            previousStart = word.startMilliseconds
        }
        return nil
    }
}
