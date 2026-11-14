import Foundation

/// Writes a transcribed audiobook's transcript text (FR05): lays the
/// transcript's sentences over the book's audio chapters, writes them into
/// the package's content.md, a heading per chapter and a paragraph per few
/// sentences, and indexes the text written, each sentence with its place in
/// the text and its stretch of the chapter's audio
/// (`BookContentTranscriptIndex`).
///
/// A transcript is kept file by file, as the recognizer heard each file,
/// while a book is read chapter by chapter: a chapter is a whole file, a
/// stretch of one (an M4B's chapter markers), or, in a segmented book such
/// as a DAISY book, a list of clips across files. Each sentence goes to the
/// chapter that plays the most of it, so one whose start the recognizer
/// placed in the pause before a chapter, which it counts as part of the
/// sentence's first word, still opens that chapter; and it is timed from the
/// chapter's start as playback counts it (`AudioClipChain`). A sentence that
/// no chapter plays, as in audio a book's navigation skips, is left out.
enum TranscriptTextBuilder {
    /// One sentence laid over a chapter: its text and the stretch of the
    /// chapter's audio it was heard in, in milliseconds from the chapter's
    /// start.
    struct ChapterSentence: Equatable, Sendable {
        var text: String
        var startMilliseconds: Int
        var endMilliseconds: Int
    }

    /// One chapter's transcript: its title and its sentences in order.
    struct ChapterTranscript: Equatable, Sendable {
        var title: String
        var sentences: [ChapterSentence]
    }

    /// The most sentences a paragraph of the text holds.
    static let sentencesPerParagraph = 4
    /// The UTF-16 length a paragraph is not let to pass by another sentence.
    static let paragraphLength = 600
    /// The silence, in milliseconds, that starts a new paragraph: a gap the
    /// recognizer left between two sentences, as around music or a long
    /// pause, that is at least this long.
    static let paragraphPause = 2_000

    // MARK: - Laying a Transcript over Chapters

    /// One stretch of an audio file that a chapter plays, with where it
    /// begins in the chapter, in milliseconds.
    private struct Stretch {
        /// The chapter playing it.
        var chapter: Int
        /// The file, as the transcript names it.
        var file: String
        /// Where the stretch begins in the file.
        var fileStart: Int
        /// Where it ends in the file, or nil when it plays to the file's end.
        var fileEnd: Int?
        /// Where it begins in the chapter.
        var chapterStart: Int

        /// How much of the file's stretch from `start` to `end` this
        /// stretch plays, in milliseconds.
        func overlap(from start: Int, to end: Int) -> Int {
            max(0, min(end, fileEnd ?? Int.max).clampedMinus(max(start, fileStart)))
        }

        /// Whether this stretch plays the file's moment `time`.
        func plays(_ time: Int) -> Bool {
            fileStart <= time && time < (fileEnd ?? Int.max)
        }

        /// `time`, a moment of the file, as a moment of the chapter, held
        /// inside this stretch.
        func chapterTime(of time: Int) -> Int {
            let elapsed = max(0, time.clampedMinus(fileStart))
            return chapterStart.clampedPlus(min(elapsed, fileEnd.map { $0.clampedMinus(fileStart) } ?? elapsed))
        }
    }

    /// Where a sentence is in its transcript: its file's place among the
    /// transcript's files, and its own among the file's sentences.
    struct SentenceAddress: Hashable, Comparable, Sendable {
        var file: Int
        var sentence: Int

        static func < (lhs: SentenceAddress, rhs: SentenceAddress) -> Bool {
            (lhs.file, lhs.sentence) < (rhs.file, rhs.sentence)
        }
    }

    /// One sentence of a transcript laid over a chapter, with where it is
    /// in the transcript, so an edit of the chapter's text can be taken back
    /// into the transcript (`TranscriptEditing`).
    struct PlacedSentence: Equatable, Sendable {
        /// Where the sentence is in the transcript.
        var address: SentenceAddress
        /// The sentence as the chapter has it.
        var sentence: ChapterSentence
    }

    /// The transcript of each chapter of `audio`, the book's audio index,
    /// in order: each chapter's title and the sentences of `transcript` it
    /// plays. `bookFileName` names a single-file book's one file, as its
    /// transcript does.
    static func chapters(of transcript: Transcript, over audio: BookContentIndex, bookFileName: String) -> [ChapterTranscript] {
        let placed = placedSentences(of: transcript, over: audio, bookFileName: bookFileName)
        return zip(audio.chapters, placed).map { chapter, sentences in
            ChapterTranscript(title: chapter.title, sentences: sentences.map(\.sentence))
        }
    }

    /// The sentences of `transcript` each chapter of `audio` plays, in the
    /// order the chapter plays them, each with where it is in the
    /// transcript; sentences heard at the same moment keep the transcript's
    /// order. A sentence no chapter plays is left out.
    static func placedSentences(of transcript: Transcript, over audio: BookContentIndex, bookFileName: String) -> [[PlacedSentence]] {
        let stretchesByFile = Dictionary(grouping: stretches(of: audio, bookFileName: bookFileName), by: \.file)
        var placed: [[PlacedSentence]] = Array(repeating: [], count: audio.chapters.count)
        for (fileNumber, file) in transcript.files.enumerated() {
            let stretches = stretchesByFile[file.path] ?? []
            for (sentenceNumber, sentence) in file.sentences.enumerated() {
                guard let stretch = bestStretch(for: sentence, among: stretches) else { continue }
                placed[stretch.chapter].append(PlacedSentence(
                    address: SentenceAddress(file: fileNumber, sentence: sentenceNumber),
                    sentence: ChapterSentence(
                        text: sentence.text,
                        startMilliseconds: stretch.chapterTime(of: sentence.startMilliseconds),
                        endMilliseconds: stretch.chapterTime(of: sentence.endMilliseconds)
                    )
                ))
            }
        }
        return placed.map { sentences in
            sentences.sortedStably {
                ($0.sentence.startMilliseconds, $0.address) < ($1.sentence.startMilliseconds, $1.address)
            }
        }
    }

    /// The stretch `sentence` is placed by: within the chapter whose
    /// stretches play the most of it, the one of them that plays the most;
    /// for a sentence lasting no time, the first stretch playing its start.
    /// Nil when no stretch plays any of it.
    private static func bestStretch(for sentence: TranscriptSentence, among stretches: [Stretch]) -> Stretch? {
        let start = sentence.startMilliseconds
        let end = sentence.endMilliseconds
        guard end > start else { return stretches.first { $0.plays(start) } }
        var chapterOverlaps: [Int: Int] = [:]
        for stretch in stretches {
            chapterOverlaps[stretch.chapter] = (chapterOverlaps[stretch.chapter] ?? 0)
                .clampedPlus(stretch.overlap(from: start, to: end))
        }
        // The chapter playing the most, the earlier of two that play as much.
        guard let chapter = chapterOverlaps
            .filter({ $0.value > 0 })
            .max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else { return nil }
        return stretches
            .filter { $0.chapter == chapter }
            .max { $0.overlap(from: start, to: end) < $1.overlap(from: start, to: end) }
    }

    /// The stretches of files the chapters of `audio` play, in chapter
    /// order, each with where it begins in its chapter, as playback times
    /// them: a segmented chapter's clips one after another
    /// (`AudioClipChain`), a multi-file book's whole files, and a single
    /// file's chapters at the starts the reader plays them from, the
    /// lengths of the chapters before each at
    /// `ReaderViewModel.audioCharsPerSecond` characters a second.
    private static func stretches(of audio: BookContentIndex, bookFileName: String) -> [Stretch] {
        if audio.audioLayout == .segmented, let segments = audio.restoredAudioSegments() {
            return segments.enumerated().flatMap { chapter, segment in
                // The chain's folder only names its clips' files, which are
                // matched here by their paths in the book instead.
                let chain = AudioClipChain(segment: segment, folder: URL(fileURLWithPath: "/", isDirectory: true))
                return segment.clips.indices.map { clip in
                    Stretch(
                        chapter: chapter,
                        file: segment.clips[clip].file,
                        fileStart: Transcript.milliseconds(chain.clips[clip].start),
                        fileEnd: chain.clips[clip].end.map(Transcript.milliseconds),
                        chapterStart: Transcript.milliseconds(chain.startTimes[clip])
                    )
                }
            }
        }
        if audio.audioLayout?.namesChapterFiles == true {
            return audio.chapters.enumerated().compactMap { chapter, entry in
                entry.audioFilePath.map { Stretch(chapter: chapter, file: $0, fileStart: 0, fileEnd: nil, chapterStart: 0) }
            }
        }
        // One file: one chapter, or chapters played one after another.
        var stretches: [Stretch] = []
        var charactersBefore = 0
        for (chapter, entry) in audio.chapters.enumerated() {
            let start = Transcript.milliseconds(AudioBookParser.time(forCharacterOffset: charactersBefore))
            charactersBefore = charactersBefore.clampedPlus(entry.characterCount)
            let end = chapter + 1 < audio.chapters.count
                ? Transcript.milliseconds(AudioBookParser.time(forCharacterOffset: charactersBefore))
                : nil
            stretches.append(Stretch(chapter: chapter, file: bookFileName, fileStart: start, fileEnd: end, chapterStart: 0))
        }
        return stretches
    }

    // MARK: - content.md

    /// The title a chapter's heading shows: its own, on one line, or, for a
    /// chapter without one, "Heading" and its number, counting from 1, so
    /// every chapter has a heading and none is dropped from content.md.
    static func headingTitle(of chapter: ChapterTranscript, number: Int) -> String {
        let title = chapter.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title.isEmpty ? "Heading \(number + 1)" : title
    }

    /// The paragraphs of `sentences`, in order: a new paragraph starts after
    /// `sentencesPerParagraph` sentences, before a sentence that would take
    /// one past `paragraphLength`, and after a silence of `paragraphPause`.
    static func paragraphs(of sentences: [ChapterSentence]) -> [[ChapterSentence]] {
        var paragraphs: [[ChapterSentence]] = []
        var current: [ChapterSentence] = []
        var length = 0
        for sentence in sentences {
            let sentenceLength = sentence.text.utf16.count
            if let previous = current.last,
               current.count >= sentencesPerParagraph
                || length + 1 + sentenceLength > paragraphLength
                || sentence.startMilliseconds.clampedMinus(previous.endMilliseconds) >= paragraphPause {
                paragraphs.append(current)
                current = []
                length = 0
            }
            length += (current.isEmpty ? 0 : 1) + sentenceLength
            current.append(sentence)
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    /// content.md for `chapters`: each chapter begins with its chapter
    /// marker and a level-1 heading of its title, then its paragraphs, each
    /// one line of its sentences with a space between them.
    ///
    /// A transcript's text counts time, not characters, and it is read in an
    /// editor and on a braille display, so it is written with only the
    /// backslashes TextMouth's own reader needs
    /// (`MarkdownLiteral.minimallyEscaped` with `smartPunctuation`, and
    /// `guardingLineStart` for a line's start): Markdown's own characters,
    /// quotes, and runs of dashes or dots, which the reader would turn into
    /// curly quotes, dashes, and ellipses. Commas, a single period, a colon,
    /// and a question mark stay as they were heard. The reader then reads the
    /// text back as exactly the transcript's characters, so each sentence is
    /// found where it lies
    /// (`locate`).
    static func markdown(of chapters: [ChapterTranscript]) -> String {
        chapters.enumerated().map { number, chapter in
            let title = headingTitle(of: chapter, number: number)
            let opening = MarkdownCacheService.chapterMarker(title: title)
                + "\n# " + MarkdownLiteral.minimallyEscaped(title, smartPunctuation: true)
            let paragraphs = paragraphs(of: chapter.sentences).map { paragraph in
                // Joined first, so a run of dashes or dots across a join is
                // seen as the one piece the reader sees.
                let joined = paragraph.map(\.text).joined(separator: " ")
                return MarkdownLiteral.guardingLineStart(MarkdownLiteral.minimallyEscaped(joined, smartPunctuation: true))
            }
            return ([opening] + paragraphs).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - The Index

    /// A transcript text written and read back: content.md's text, the
    /// chapters it parses to, and their index with each sentence placed.
    struct Text {
        /// content.md as written.
        var markdown: String
        /// The reading text, parsed from `markdown` as any content.md is.
        var chapters: [Chapter]
        /// The reading text's index, as a text book's is made.
        var readingIndex: BookContentIndex
        /// Each chapter's sentences, where each lies in its chapter's text.
        var sentences: [[BookContentSentenceIndex]]
    }

    /// The text of `chapters`, the transcript of a book titled `bookTitle`
    /// by `bookAuthor`: written as content.md and parsed back as content.md
    /// is read, so its index and sentence offsets describe exactly the text
    /// the reader shows. Nil when the parse does not give back one chapter
    /// for each, which a heading in every chapter prevents.
    static func text(of chapters: [ChapterTranscript], bookTitle: String, bookAuthor: String) -> Text? {
        let markdown = markdown(of: chapters)
        let parsed = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: bookTitle, bookAuthor: bookAuthor)
        guard parsed.chapters.count == chapters.count else { return nil }
        let readingIndex = BookContentIndex.build(fromChapters: parsed.chapters, format: .markdown)
        let sentences = zip(chapters, parsed.chapters).map { chapter, parsedChapter in
            locate(chapter.sentences, in: parsedChapter.text)
        }
        return Text(markdown: markdown, chapters: parsed.chapters, readingIndex: readingIndex, sentences: sentences)
    }

    /// Where each of `sentences` lies in `text`, the chapter's reading
    /// text, in order: each found as written, starting where the one before
    /// it ended. Written as `markdown(of:)` writes it, a sentence reads back as
    /// itself, a separator away from the one before, so each is found at
    /// once; one not found, which would mean the text was not read back as
    /// written, is left out rather than placed wrongly.
    static func locate(_ sentences: [ChapterSentence], in text: String) -> [BookContentSentenceIndex] {
        let haystack = Array(text.utf16)
        var located: [BookContentSentenceIndex] = []
        var cursor = 0
        for sentence in sentences {
            let needle = Array(sentence.text.utf16)
            guard !needle.isEmpty, let found = firstOccurrence(of: needle, in: haystack, from: cursor) else { continue }
            located.append(BookContentSentenceIndex(
                characterOffset: found,
                characterCount: needle.count,
                startMilliseconds: sentence.startMilliseconds,
                endMilliseconds: max(sentence.endMilliseconds, sentence.startMilliseconds)
            ))
            cursor = found + needle.count
        }
        return located
    }

    /// Where `needle` first occurs in `haystack` at or after `start`, or nil.
    private static func firstOccurrence(of needle: [UTF16.CodeUnit], in haystack: [UTF16.CodeUnit], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var position = start
        while position <= haystack.count - needle.count {
            if haystack[position] == needle[0], haystack[position..<(position + needle.count)].elementsEqual(needle) {
                return position
            }
            position += 1
        }
        return nil
    }

    /// The index of `text`, written from `transcript`, whose transcript.json
    /// and content.md `fingerprint` describes.
    static func index(of text: Text, from transcript: Transcript, fingerprint: TextCacheFingerprint) -> BookContentTranscriptIndex {
        BookContentTranscriptIndex(
            version: BookContentTranscriptIndex.currentVersion,
            transcript: transcript.note,
            textCacheFingerprint: fingerprint,
            audioFiles: transcript.audioFiles,
            totalWordCount: text.readingIndex.totalWordCount,
            totalCharacterCount: text.readingIndex.totalCharacterCount,
            chapters: zip(text.readingIndex.chapters, text.sentences).map {
                BookContentTranscriptChapterIndex(text: $0, sentences: $1)
            }
        )
    }
}

// MARK: - Arithmetic That Cannot Trap

extension Int {
    /// This number plus `other`, held at `Int.max` or `Int.min` rather than
    /// trapping: the times and lengths read from a book's files are untrusted,
    /// and a damaged one must not crash TextMouth. The transcript text
    /// builder uses it, and so do a transcript's captions (FMT23): their
    /// times on the book's timeline (`Transcript.bookTimelineCues`) and
    /// their timing lines; and a transcript from outside, laying a book's
    /// files one after another on its timeline (`OutsideTranscript`).
    func clampedPlus(_ other: Int) -> Int {
        let (sum, overflowed) = addingReportingOverflow(other)
        // An overflow runs in the direction the added number points.
        return overflowed ? (other < 0 ? Int.min : Int.max) : sum
    }

    /// This number minus `other`, held at `Int.max` or `Int.min` rather than
    /// trapping.
    func clampedMinus(_ other: Int) -> Int {
        let (difference, overflowed) = subtractingReportingOverflow(other)
        // An overflow runs the opposite way to the subtracted number.
        return overflowed ? (other < 0 ? Int.max : Int.min) : difference
    }
}
