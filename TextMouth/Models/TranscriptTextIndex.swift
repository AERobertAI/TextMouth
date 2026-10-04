import Foundation

// MARK: - The Transcript Text in a Content Index

/// A transcribed audiobook's transcript text, as its content index records
/// it (FR05): the text's own index, the stretch of each chapter's audio each
/// of its sentences was heard in, and what the text was written from.
///
/// An audiobook's content index stays its audio index, chapter for chapter
/// and second for second: its positions and bookmarks count time, as they
/// always have, and the book plays as it always did. The transcript text is
/// laid over it, the way a DAISY book's text is laid over its audio: one
/// chapter of text for each chapter of audio, written into the package's
/// content.md (a heading per chapter, a paragraph per few sentences), and
/// each sentence aligned with the stretch of its chapter's audio it was
/// heard in, so a place in the text has a time and a time has a place in
/// the text (`TranscriptText`). The text is derived: transcript.json is its
/// source, content.md its cache, fingerprinted as a text book's cache is
/// (TODO T07), and either can be written again from the transcript.
struct BookContentTranscriptIndex: Codable, Hashable, Sendable {
    /// How the text is written from a transcript and aligned with the audio.
    /// A change to either changes this version, and each transcribed book's
    /// text is then written again from its transcript.json as it opens.
    static let currentVersion = "1.0.0"

    /// The version of the writing and alignment this index was made by.
    var version: String
    /// The transcript the text was written from, as the book's record notes
    /// it (`BookState.transcript`).
    var transcript: TranscriptNote
    /// The transcript.json the text was written from (the source) and the
    /// content.md it was written into (the cache), as each was then.
    var textCacheFingerprint: TextCacheFingerprint
    /// Each audio file the transcript describes, with its fingerprint when
    /// it was transcribed: a file whose size or contents differ now has
    /// changed since, and the text no longer describes the book's audio.
    var audioFiles: [TranscriptAudioFile]
    /// The words in the transcript text, as a text book's index counts them.
    var totalWordCount: Int
    /// The transcript text's length in UTF-16 units.
    var totalCharacterCount: Int
    /// One entry for each chapter of the audio index, in order.
    var chapters: [BookContentTranscriptChapterIndex]

    /// Whether this index was made by the current writing and alignment.
    var isCurrent: Bool {
        version == Self.currentVersion
    }

    /// The transcript text's own index, laid out as a text book's: its
    /// chapters, headings, and counts, with the fingerprints of the files it
    /// came from. A load checks the parsed content.md against it as it
    /// checks a text book's (`BookContentIndex.alignmentFailure`), and the
    /// transcript's text is read with it.
    var readingIndex: BookContentIndex {
        BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .text,
            format: .markdown,
            generatedAt: transcript.createdAt,
            totalWordCount: totalWordCount,
            totalCharacterCount: totalCharacterCount,
            totalAudioDuration: nil,
            audioLayout: nil,
            chapters: chapters.map(\.text),
            textCacheFingerprint: textCacheFingerprint
        )
    }

    /// Why this index cannot be trusted with the audio index `audio`, the
    /// book's own, or nil when it can: it must be current, give each of the
    /// audio's chapters one entry, pass validation as a text index of its
    /// own, and place each chapter's sentences in order inside the
    /// chapter's text and time. The reason names the first offending field
    /// and never quotes the book's text.
    func validationFailure(against audio: BookContentIndex) -> String? {
        if !isCurrent {
            return "transcript.version \(String(reflecting: version)) is not the current "
                + String(reflecting: Self.currentVersion)
        }
        if chapters.count != audio.chapters.count {
            return "transcript.chapters has \(chapters.count) entries, but the audio has \(audio.chapters.count) chapters"
        }
        if let failure = readingIndex.validationFailure(for: .markdown, audioBaseURL: nil) {
            return "transcript: \(failure)"
        }
        for (number, chapter) in chapters.enumerated() {
            if let failure = chapter.sentenceFailure(field: "transcript.chapters[\(number)]") {
                return failure
            }
        }
        return nil
    }

    /// This index's chapter `chapterIndex`, or nil when there is none.
    func chapter(_ chapterIndex: Int) -> BookContentTranscriptChapterIndex? {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
    }
}

/// One audio file a transcript describes, as the transcript text's index
/// keeps it: its place in the book and its fingerprint when transcribed.
struct TranscriptAudioFile: Codable, Hashable, Sendable {
    /// The file's path relative to the book's audio folder, or, for a book
    /// of one file, its name (`TranscriptFile.path`).
    var path: String
    /// The file as it was when transcribed.
    var fingerprint: FileFingerprint
}

extension Transcript {
    /// The audio files this transcript describes, with their fingerprints
    /// when they were transcribed.
    var audioFiles: [TranscriptAudioFile] {
        files.map { TranscriptAudioFile(path: $0.path, fingerprint: $0.fingerprint) }
    }
}

/// One chapter of a transcribed audiobook's transcript text.
struct BookContentTranscriptChapterIndex: Codable, Hashable, Sendable {
    /// The chapter's text as a text book's index records a chapter: its
    /// place in the transcript text, length, words, and headings.
    var text: BookContentChapterIndex
    /// The chapter's sentences, in order, each where it lies in the
    /// chapter's text and when it was heard in the chapter's audio.
    var sentences: [BookContentSentenceIndex]

    /// Why the sentences cannot be trusted, naming the first offending one
    /// after `field`, or nil when each lies, in order, inside the chapter's
    /// text, and starts no earlier than the one before it.
    fileprivate func sentenceFailure(field: String) -> String? {
        var previousEnd = 0
        var previousStart = 0
        for (number, sentence) in sentences.enumerated() {
            let field = "\(field).sentences[\(number)]"
            if sentence.characterCount <= 0 || sentence.characterOffset < previousEnd
                || sentence.characterOffset > text.characterCount - sentence.characterCount {
                return "\(field) spans characters \(sentence.characterOffset) to "
                    + "\(sentence.characterOffset + sentence.characterCount), outside \(previousEnd) through \(text.characterCount)"
            }
            if sentence.startMilliseconds < previousStart || sentence.endMilliseconds < sentence.startMilliseconds {
                return "\(field) runs from \(sentence.startMilliseconds) to \(sentence.endMilliseconds) ms, "
                    + "before \(previousStart) or backwards"
            }
            previousEnd = sentence.characterOffset + sentence.characterCount
            previousStart = sentence.startMilliseconds
        }
        return nil
    }
}

/// One sentence of a chapter's transcript text and the stretch of the
/// chapter's audio it was heard in, the way a DAISY book's synchronization
/// pairs a phrase of text with a clip of audio.
///
/// The index writes a sentence as four whole numbers, since a long book
/// holds tens of thousands: its UTF-16 offset and length in the chapter's
/// text, and its start and end in milliseconds from the chapter's start, as
/// the chapter plays (a segmented chapter's clips one after another), as in
/// `[1204, 61, 95040, 99300]`.
struct BookContentSentenceIndex: Hashable, Sendable {
    /// Where the sentence begins in its chapter's text, in UTF-16 units.
    var characterOffset: Int
    /// The sentence's length in UTF-16 units.
    var characterCount: Int
    /// When the sentence begins in the chapter's audio, in milliseconds.
    var startMilliseconds: Int
    /// When it ends, in milliseconds.
    var endMilliseconds: Int

    /// Where the sentence ends in its chapter's text, in UTF-16 units.
    var characterEnd: Int {
        characterOffset + characterCount
    }
}

extension BookContentSentenceIndex: Codable {
    /// Reads a sentence as the index writes it: four whole numbers.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        characterOffset = try container.decode(Int.self)
        characterCount = try container.decode(Int.self)
        startMilliseconds = try container.decode(Int.self)
        endMilliseconds = try container.decode(Int.self)
    }

    /// Writes a sentence as four whole numbers.
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(characterOffset)
        try container.encode(characterCount)
        try container.encode(startMilliseconds)
        try container.encode(endMilliseconds)
    }
}

// MARK: - The Text and Its Timing

/// A transcribed audiobook's transcript text, ready to show: each chapter's
/// reading text, parsed from content.md, with the sentences of its index,
/// which give a place in the text a time in the chapter's audio and a time a
/// place in the text (FR05).
///
/// The cursor follows the narration sentence by sentence: a time places it
/// at the start of the sentence being heard, or, in a pause, of the sentence
/// about to be, since the recognizer counts a pause as part of the word after
/// it; and a place in the text has the time its sentence begins, so playing
/// from a place in the text starts that sentence. Text before a chapter's
/// first sentence, its heading, has the chapter's start.
///
/// An audiobook's reader keeps its cursor in time (`ReaderViewModel`'s
/// audio cursor counts `ReaderViewModel.audioCharsPerSecond` characters a
/// second), which `textOffset(atAudioOffset:inChapter:)` and
/// `audioOffset(atTextOffset:inChapter:)` convert.
struct TranscriptText: Sendable {
    /// Each chapter's reading text, parsed from content.md, in the order of
    /// the audio's chapters.
    let chapters: [Chapter]
    /// The transcript text's index, with each chapter's sentences.
    let index: BookContentTranscriptIndex

    /// The reading text of chapter `chapterIndex`, or nil when there is none.
    func chapterText(_ chapterIndex: Int) -> String? {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].text : nil
    }

    /// The sentence of chapter `chapterIndex` heard `milliseconds` into the
    /// chapter: the last to begin by then, or, past its end in a pause, the
    /// one after it. Nil before the chapter's first sentence, or for a
    /// chapter without sentences.
    func sentence(atMilliseconds milliseconds: Int, inChapter chapterIndex: Int) -> BookContentSentenceIndex? {
        guard let sentences = index.chapter(chapterIndex)?.sentences,
              let last = Self.lastIndex(in: sentences, where: { $0.startMilliseconds <= milliseconds }) else {
            return nil
        }
        if milliseconds >= sentences[last].endMilliseconds, last + 1 < sentences.count {
            return sentences[last + 1]
        }
        return sentences[last]
    }

    /// Where in chapter `chapterIndex`'s text the narration is `seconds`
    /// into the chapter: the start of the sentence heard then
    /// (`sentence(atMilliseconds:inChapter:)`), or the chapter's start
    /// before its first sentence.
    func textOffset(atChapterTime seconds: TimeInterval, inChapter chapterIndex: Int) -> Int {
        sentence(atMilliseconds: Transcript.milliseconds(seconds), inChapter: chapterIndex)?.characterOffset ?? 0
    }

    /// How far into chapter `chapterIndex`'s audio, in seconds, the place
    /// `offset` in its text was heard: the start of the sentence holding it,
    /// of the sentence after it when it lies between sentences, or of the
    /// last sentence's end past every sentence; the chapter's start before
    /// its first sentence.
    func chapterTime(atTextOffset offset: Int, inChapter chapterIndex: Int) -> TimeInterval {
        guard let sentences = index.chapter(chapterIndex)?.sentences,
              let holding = Self.lastIndex(in: sentences, where: { $0.characterOffset <= offset }) else {
            return 0
        }
        let sentence = sentences[holding]
        if offset < sentence.characterEnd {
            return Transcript.seconds(sentence.startMilliseconds)
        }
        if holding + 1 < sentences.count {
            return Transcript.seconds(sentences[holding + 1].startMilliseconds)
        }
        return Transcript.seconds(sentence.endMilliseconds)
    }

    /// Where in chapter `chapterIndex`'s text the narration is at
    /// `audioOffset`, a reader's audio cursor in that chapter, which counts
    /// `ReaderViewModel.audioCharsPerSecond` characters a second.
    func textOffset(atAudioOffset audioOffset: Int, inChapter chapterIndex: Int) -> Int {
        textOffset(atChapterTime: AudioBookParser.time(forCharacterOffset: audioOffset), inChapter: chapterIndex)
    }

    /// The reader's audio cursor in chapter `chapterIndex` for the place
    /// `offset` in its text: the time that place was heard
    /// (`chapterTime(atTextOffset:inChapter:)`), as the audio cursor counts it.
    func audioOffset(atTextOffset offset: Int, inChapter chapterIndex: Int) -> Int {
        AudioBookParser.characterOffset(forTime: chapterTime(atTextOffset: offset, inChapter: chapterIndex))
    }

    /// The last index of `sentences`, which are in order, at which
    /// `isBefore` holds, found by halving: `isBefore` holds for a leading
    /// run of them and for none after. Nil when it holds for none.
    private static func lastIndex(
        in sentences: [BookContentSentenceIndex],
        where isBefore: (BookContentSentenceIndex) -> Bool
    ) -> Int? {
        var low = 0
        var high = sentences.count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(sentences[middle]) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }
}
