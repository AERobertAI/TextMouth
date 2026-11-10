import Foundation

// MARK: - A Transcript from Outside (FMT23, FMT25)

/// Makes a book's transcript from timed sentences that TextMouth's
/// recognizer did not hear: a WebVTT or SubRip file attached to the book or
/// found beside its audio at import (FMT23), or a podcast's own transcript,
/// fetched with the episode (FMT25).
///
/// The transcript is made as recognition makes one, so the rest of
/// TextMouth saves it, writes its text, and checks its audio alike
/// (`TranscriptStore.install`): each of the book's audio files, in the
/// order the book first plays them (`TranscriptionPlan`), measured and
/// fingerprinted, with the sentences spoken in it, timed from the file's own
/// start. It names no recognizer (`noRecognizer`) and no language
/// (`undeterminedLocale`), and records where it came from
/// (`TranscriptSource`).
///
/// A transcript made for other audio is refused rather than laid over this
/// book's: one whose last sentence ends more than
/// `TimedTextLimits.pastTheEndMarginMilliseconds` after the end of its audio
/// (`checkFits`).
enum OutsideTranscript {
    /// The language of a transcript from outside: BCP 47's "undetermined".
    /// A timed-text file rarely says its language, and a transcript must
    /// name one to be used (`Transcript.validationFailure()`).
    static let undeterminedLocale = "und"

    /// The recognizer of a transcript from outside: none. Its engine and its
    /// model's status are "none", and its system is the one that made the
    /// transcript, as recognition records the system whose model it used.
    static var noRecognizer: TranscriptSpeechModel {
        TranscriptSpeechModel(
            engine: "none",
            assetStatus: "none",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    // MARK: Fitting the Audio

    /// Throws `OutsideTranscriptError.runsPastTheEnd` when the latest end
    /// among `sentences` lies more than
    /// `TimedTextLimits.pastTheEndMarginMilliseconds` after
    /// `durationMilliseconds`, the end of their audio: such a transcript was
    /// made for other audio. Ending exactly the margin past the end is
    /// accepted, and so are no sentences.
    static func checkFits(_ sentences: [TranscriptSentence], durationMilliseconds: Int) throws {
        guard let transcriptEnd = sentences.lazy.map(\.endMilliseconds).max() else { return }
        // Only an end past the audio's is measured, as the difference of
        // two numbers no less than 0, which no time read from a file can
        // make overflow.
        let audioEnd = max(0, durationMilliseconds)
        guard transcriptEnd > audioEnd,
              transcriptEnd - audioEnd > TimedTextLimits.pastTheEndMarginMilliseconds else { return }
        throw OutsideTranscriptError.runsPastTheEnd(transcriptEnd: transcriptEnd, audioEnd: durationMilliseconds)
    }

    // MARK: Cutting the Book's Timeline into Its Files

    /// `sentences`, timed on the book's timeline, cut into the audio files
    /// `files` they were spoken in, each file's by its path, as a podcast's
    /// transcript of the whole episode, or one file timing a book of many
    /// tracks, is read.
    ///
    /// The book's timeline is its files one after another, whole, in the
    /// order of `files`; each file lasts `Transcript.milliseconds(_:)` of its
    /// duration, so it starts where the lengths of the files before it add
    /// up to. Each sentence goes to the last file that starts at or before
    /// the sentence's start: a sentence starting exactly where a file
    /// starts goes to that file, and one starting at or past the book's end
    /// to its last file. A file of no length takes no sentence; a sentence
    /// starting before the book's first moment, which no reader gives, goes
    /// to the first file of some length.
    ///
    /// In its file, a sentence's start and end are counted from the file's
    /// start, each held inside the file, so one running on into the next
    /// file ends where its own file does. Its words move with it, and are
    /// kept only when every one still lies inside the sentence's new time;
    /// otherwise the sentence keeps no words. Each file's sentences keep
    /// their order, and a file that takes none is absent from the result.
    static func split(
        _ sentences: [TranscriptSentence],
        across files: [TranscriptionPlan.File]
    ) -> [String: [TranscriptSentence]] {
        // Only a file of some length can hold a sentence.
        let spans = timeline(of: files).filter { $0.length > 0 }
        guard !spans.isEmpty else { return [:] }
        var split: [String: [TranscriptSentence]] = [:]
        for sentence in sentences {
            let span = spans[lastSpanIndex(startingAtOrBefore: sentence.startMilliseconds, in: spans)]
            if let placed = span.place(sentence) {
                split[span.path, default: []].append(placed)
            }
        }
        return split
    }

    /// `sentence`, timed from the start of its file, as a transcript of that
    /// file may hold it: nil for a sentence that starts past
    /// `Transcript.maximumMilliseconds`, 100 hours, which no file's
    /// transcript times; a sentence that runs past them ends there, its
    /// words kept only when each still ends inside it. The cue readers take
    /// times to 1,000 hours, since a book's whole transcript runs on its
    /// timeline (`TimedTextLimits.maximumCueMilliseconds`), so a file longer
    /// than 100 hours is left out past its hundredth hour, as the readers
    /// left cues out before, and not refused whole as unusable.
    static func withinTheLimitOfAFile(_ sentence: TranscriptSentence) -> TranscriptSentence? {
        let limit = Transcript.maximumMilliseconds
        guard sentence.startMilliseconds <= limit else { return nil }
        guard sentence.endMilliseconds > limit else { return sentence }
        var held = sentence
        held.endMilliseconds = limit
        if !held.words.allSatisfy({ $0.endMilliseconds <= limit }) {
            held.words = []
        }
        return held
    }

    /// One audio file laid on the book's timeline, in milliseconds.
    private struct Span {
        /// The file's path in the book (`TranscriptionPlan.File.path`).
        let path: String
        /// Where the file starts on the book's timeline: the lengths of the
        /// files before it, added up.
        let start: Int
        /// How long the file plays (`Transcript.milliseconds(_:)` of its
        /// duration).
        let length: Int

        /// Where the file ends on the book's timeline: held at `Int.max`
        /// rather than trapping, so a book's files, however long they claim
        /// to be, add up to a time that never overflows (`clampedPlus`).
        var end: Int {
            start.clampedPlus(length)
        }

        /// `sentence`, timed on the book's timeline, moved into this file:
        /// its start and end counted from the file's start, each held inside
        /// the file, and its words moved with it, kept only when every one
        /// begins and ends inside the sentence's new time, in order;
        /// otherwise it keeps none. In a file longer than the 100 hours a
        /// transcript may time (`Transcript.maximumMilliseconds`), a sentence
        /// that starts past them is left out (nil) and one that runs past
        /// them ends there (`OutsideTranscript.withinTheLimitOfAFile(_:)`).
        func place(_ sentence: TranscriptSentence) -> TranscriptSentence? {
            // Held inside the file on the book's timeline before anything
            // moves, so every time that moves lies at or after the file's
            // start and no subtraction can overflow, whatever the file said.
            let heldStart = hold(sentence.startMilliseconds)
            let heldEnd = hold(sentence.endMilliseconds)
            let wordsFit = sentence.words.allSatisfy { word in
                heldStart <= word.startMilliseconds
                    && word.startMilliseconds <= word.endMilliseconds
                    && word.endMilliseconds <= heldEnd
            }
            var placed = sentence
            placed.startMilliseconds = heldStart - start
            placed.endMilliseconds = heldEnd - start
            placed.words = wordsFit ? sentence.words.map(moved) : []
            return OutsideTranscript.withinTheLimitOfAFile(placed)
        }

        /// `time`, on the book's timeline, held inside this file.
        private func hold(_ time: Int) -> Int {
            min(max(time, start), end)
        }

        /// `word`, timed on the book's timeline and lying inside this file,
        /// timed from the file's start instead.
        private func moved(_ word: TranscriptWord) -> TranscriptWord {
            var word = word
            word.startMilliseconds -= start
            word.endMilliseconds -= start
            return word
        }
    }

    /// `files` laid one after another on the book's timeline, in order.
    private static func timeline(of files: [TranscriptionPlan.File]) -> [Span] {
        var spans: [Span] = []
        var start = 0
        for file in files {
            let span = Span(path: file.path, start: start, length: Transcript.milliseconds(file.duration))
            spans.append(span)
            start = span.end
        }
        return spans
    }

    /// The index in `spans`, which are in the order they start, of the last
    /// that starts at or before `time`; 0, the first, when none does.
    private static func lastSpanIndex(startingAtOrBefore time: Int, in spans: [Span]) -> Int {
        // A binary search for the first span that starts after `time`, so a
        // transcript of many sentences over a book of many files is cut in
        // little time; the span before that one is the last that starts at
        // or before it.
        var low = 0
        var high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }

    // MARK: Making the Transcript

    /// The transcript of the book whose audio `plan` lists, made from
    /// `sentencesByFile`, each audio file's sentences by its path in the
    /// book, timed from that file's own start, as a timed-text file found
    /// beside each track gives them; `source` says where they came from.
    ///
    /// Each of the plan's files, in order, becomes one of the transcript's,
    /// with its sentences (none when `sentencesByFile` names it not), its
    /// fingerprint as it is now, read with `hasher`, and its length, as
    /// recognition makes a transcript; sentences of a path the plan does
    /// not list are passed over. The transcript names no recognizer and no
    /// language, was made by this build at `now`, in whole seconds, and
    /// records `source`.
    ///
    /// Every file's sentences are checked against its length before any
    /// file is read, so a transcript that cannot be used is refused without
    /// reading the book's audio. Fingerprinting reads each audio file whole,
    /// so this blocks: call it off the main thread.
    /// - Throws: `OutsideTranscriptError.runsPastTheEnd` for a file whose
    ///   sentences run past its end (`checkFits`), `.noText` when no file
    ///   has a sentence, `TranscriptionError.unreadableFile` naming a file
    ///   that cannot be fingerprinted, and `OutsideTranscriptError.unusable`
    ///   for sentences whose times do not fit together
    ///   (`Transcript.validationFailure()`).
    static func transcript(
        sentencesByFile: [String: [TranscriptSentence]],
        plan: TranscriptionPlan,
        source: TranscriptSource,
        now: Date = Date(),
        hasher: FingerprintHasher = .md5
    ) throws -> Transcript {
        // Each of the plan's files' sentences, in the plan's order.
        let sentencesInOrder = try plan.files.map { file -> [TranscriptSentence] in
            // A file longer than 100 hours keeps no sentence past them
            // (`withinTheLimitOfAFile(_:)`).
            let fileSentences = (sentencesByFile[file.path] ?? []).compactMap(withinTheLimitOfAFile)
            try checkFits(fileSentences, durationMilliseconds: Transcript.milliseconds(file.duration))
            return fileSentences
        }
        guard sentencesInOrder.contains(where: { !$0.isEmpty }) else { throw OutsideTranscriptError.noText }
        let files = try zip(plan.files, sentencesInOrder).map { file, fileSentences in
            guard let fingerprint = FileFingerprint(of: file.url, hasher: hasher) else {
                throw TranscriptionError.unreadableFile(file: file.path, reason: TranscriptionError.unreadableAudioReason)
            }
            return TranscriptFile(
                path: file.path,
                fingerprint: fingerprint,
                durationMilliseconds: Transcript.milliseconds(file.duration),
                sentences: fileSentences
            )
        }
        let transcript = Transcript(
            version: Transcript.currentVersion,
            locale: undeterminedLocale,
            model: noRecognizer,
            app: .current,
            // Whole seconds, as transcript.json keeps its dates and as
            // recognition stamps its transcripts.
            createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
            files: files,
            source: source
        )
        if let reason = transcript.validationFailure() {
            throw OutsideTranscriptError.unusable(reason)
        }
        return transcript
    }

    /// The transcript of the book whose audio `plan` lists, made from
    /// `sentences` timed on the book's timeline (its files one after
    /// another, whole), as a podcast's transcript of the whole episode
    /// gives them; `source` says where they came from.
    ///
    /// The sentences are checked against the length of the whole book
    /// first, then cut into its files (`split(_:across:)`), and the
    /// transcript is made from those as
    /// `transcript(sentencesByFile:plan:source:now:hasher:)` makes it, which
    /// says what is thrown.
    static func transcript(
        bookTimeline sentences: [TranscriptSentence],
        plan: TranscriptionPlan,
        source: TranscriptSource,
        now: Date = Date(),
        hasher: FingerprintHasher = .md5
    ) throws -> Transcript {
        try checkFits(sentences, durationMilliseconds: timeline(of: plan.files).last?.end ?? 0)
        return try transcript(
            sentencesByFile: split(sentences, across: plan.files),
            plan: plan,
            source: source,
            now: now,
            hasher: hasher
        )
    }
}

// MARK: - Why a Transcript from Outside Is Not Used

/// Why a transcript from outside was not given to its book, in words a
/// listener understands, the same on screen, in VoiceOver, and in braille.
/// A description never quotes the transcript's text, which is the book's.
enum OutsideTranscriptError: LocalizedError, Equatable {
    /// The transcript runs on more than
    /// `TimedTextLimits.pastTheEndMarginMilliseconds` past the end of its
    /// audio, so it was made for other audio: where its last sentence ends,
    /// and where the audio ends, in milliseconds.
    case runsPastTheEnd(transcriptEnd: Int, audioEnd: Int)
    /// The transcript holds no sentence for any of the book's audio files.
    case noText
    /// The book has a transcript already, which the install was asked to
    /// keep (`TranscriptStore.install`'s `keepingExisting`), so it was.
    case alreadyTranscribed
    /// The transcript's times do not fit together, for the reason given
    /// (`Transcript.validationFailure()`): for the debug log alone. It
    /// names fields and numbers, never the transcript's words, and the
    /// listener is told the description instead.
    case unusable(String)

    var errorDescription: String? {
        switch self {
        case .runsPastTheEnd(let transcriptEnd, let audioEnd):
            return "The transcript runs to \(Self.spoken(transcriptEnd)), past the end of the audio at "
                + "\(Self.spoken(audioEnd)), so it was made for other audio."
        case .noText:
            return "The transcript holds no text to attach."
        case .alreadyTranscribed:
            return "The book has a transcript already, so TextMouth kept it."
        case .unusable:
            return "The transcript's times don't fit together, so TextMouth can't use it."
        }
    }

    /// `milliseconds` as words VoiceOver speaks, such as "1 hour, 2 minutes,
    /// 5 seconds" (`TimeFormatting.spoken(_:)`).
    private static func spoken(_ milliseconds: Int) -> String {
        TimeFormatting.spoken(Double(milliseconds) / 1_000)
    }
}
