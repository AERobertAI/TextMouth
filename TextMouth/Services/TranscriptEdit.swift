import Foundation

/// Why an edit of a transcribed audiobook's text could not be taken into its
/// transcript (FR05).
enum TranscriptEditError: Error, Equatable {
    /// transcript.json cannot be read now: it is gone, only in the cloud,
    /// unusable, or of a layout this TextMouth does not read.
    case transcriptUnavailable
    /// The edited text holds `found` chapters, where the audiobook has
    /// `expected`: a transcript's text keeps one chapter for each of the
    /// audio's.
    case chaptersChanged(found: Int, expected: Int)
    /// A chapter's heading in the edited text is not the one the transcript
    /// gives that chapter, or a heading was removed or added: a heading comes
    /// from the audio, so the transcript has nowhere to keep another.
    case headingChanged
    /// A chapter the transcript heard no speech in holds words besides its
    /// heading in the edited text: with no sentence to take them, they
    /// could not be kept.
    case wordsWithoutSentences
    /// The book's audio is not the audio transcribed any more, for the
    /// reason given (`TranscriptTextLoader.audioCheck`).
    case audioChanged(String)
    /// The edited text could not be indexed against the audio, for the
    /// reason given, which names a field and never quotes the text.
    case unindexable(String)
}

/// Takes the user's edit of a transcribed audiobook's text into its
/// transcript (FR05), so the edit is what the transcript says from then on.
///
/// The book's text, content.md, is written from transcript.json, and the
/// text's loader writes it again from there whenever the two disagree. So
/// an edit of content.md is laid over the transcript's sentences
/// (`TranscriptEditAlignment`): each sentence takes the words that stand for
/// it in the edit and keeps its time in the audio; a sentence whose text
/// changed drops its words' timings, which no longer fit it; a sentence the
/// edit deleted is gone; and the transcript is marked edited by the user,
/// with the date.
enum TranscriptEditing {
    /// `transcript` with the edit `chapters` taken, content.md as the user
    /// saved it and parsed, laid over the book's audio index `audioIndex`
    /// (without the text's layer), whose single file, for a book of one, is
    /// `bookFileName`; and each chapter's sentences, where each lies in the
    /// edited chapter's text and when it is heard in the chapter's audio.
    /// The transcript is marked edited at `editedAt`.
    /// - Throws: `TranscriptEditError.chaptersChanged` when the edit does not
    ///   keep one chapter for each of the audio's; `.headingChanged` when a
    ///   chapter's heading is not the transcript's (renamed, removed, or
    ///   another added); `.wordsWithoutSentences` when a chapter without
    ///   sentences holds words besides its heading. Each is thrown before
    ///   any sentence is aligned, as the transcript has nowhere to keep
    ///   what these edits changed.
    static func apply(
        _ chapters: [Chapter],
        to transcript: Transcript,
        over audioIndex: BookContentIndex,
        bookFileName: String,
        editedAt: Date
    ) throws -> (transcript: Transcript, sentences: [[BookContentSentenceIndex]]) {
        let placed = TranscriptTextBuilder.placedSentences(of: transcript, over: audioIndex, bookFileName: bookFileName)
        guard chapters.count == placed.count else {
            throw TranscriptEditError.chaptersChanged(found: chapters.count, expected: placed.count)
        }
        try checkOutsideSentences(chapters, placed: placed, over: audioIndex)
        var edited = transcript
        var removed = Set<TranscriptTextBuilder.SentenceAddress>()
        var located: [[BookContentSentenceIndex]] = []
        for (chapter, sentences) in zip(chapters, placed) {
            let text = chapter.text as NSString
            let ranges = TranscriptEditAlignment.ranges(
                of: sentences.map(\.sentence.text),
                in: chapter.text,
                excluding: headingRanges(in: chapter)
            )
            var chapterSentences: [BookContentSentenceIndex] = []
            for (sentence, range) in zip(sentences, ranges) {
                let address = sentence.address
                guard let range else {
                    removed.insert(address)
                    continue
                }
                // A transcript's sentence is one line, a space between each
                // two words: an edit's line or paragraph break inside it
                // reads as one.
                let words = text.substring(with: range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                edited.files[address.file].sentences[address.sentence].rewrite(as: words)
                chapterSentences.append(BookContentSentenceIndex(
                    characterOffset: range.location,
                    characterCount: range.length,
                    startMilliseconds: sentence.sentence.startMilliseconds,
                    endMilliseconds: max(sentence.sentence.endMilliseconds, sentence.sentence.startMilliseconds)
                ))
            }
            located.append(chapterSentences)
        }
        if !removed.isEmpty {
            for file in edited.files.indices {
                edited.files[file].sentences = edited.files[file].sentences.enumerated()
                    .filter { !removed.contains(TranscriptTextBuilder.SentenceAddress(file: file, sentence: $0.offset)) }
                    .map(\.element)
            }
        }
        edited.editedAt = editedAt
        return (edited, located)
    }

    /// Throws when `chapters`, the edited text, changes what the transcript
    /// cannot hold: text outside its sentences. Only the sentences are laid
    /// over the transcript, so a chapter's heading, which is written from the
    /// audio's chapter title, and words typed into a chapter with no
    /// sentences would be announced as taken and then lost the next time the
    /// text is written from transcript.json.
    /// - Parameters:
    ///   - chapters: The edited text's chapters, one for each of the audio's.
    ///   - placed: The transcript's sentences in each of the audio's chapters.
    ///   - audioIndex: The book's audio index, which names each chapter.
    private static func checkOutsideSentences(
        _ chapters: [Chapter],
        placed: [[TranscriptTextBuilder.PlacedSentence]],
        over audioIndex: BookContentIndex
    ) throws {
        for (number, ((chapter, sentences), audioChapter)) in zip(zip(chapters, placed), audioIndex.chapters).enumerated() {
            let ranges = headingRanges(in: chapter)
            // The one heading content.md gives the chapter, as the text
            // builder writes it.
            let expected = TranscriptTextBuilder.headingTitle(
                of: TranscriptTextBuilder.ChapterTranscript(title: audioChapter.title, sentences: []),
                number: number
            )
            // Every heading found must be that one, with white space taken as
            // one space: a heading gone (the parser then makes one up, which
            // headingRanges leaves out) or added differs from [expected].
            let found = ranges.map { range in
                (chapter.text as NSString).substring(with: range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            guard found == [expected] else { throw TranscriptEditError.headingChanged }
            guard sentences.isEmpty else { continue }
            // No sentence to take words: all that is left outside the heading
            // must be white space.
            if hasWordsOutside(ranges, in: chapter.text) { throw TranscriptEditError.wordsWithoutSentences }
        }
    }

    /// Whether `text` holds anything but white space outside `ranges`.
    private static func hasWordsOutside(_ ranges: [NSRange], in text: String) -> Bool {
        var rest = text as NSString
        // Cut the ranges out from the last, so each earlier range still lies
        // where it did.
        for range in ranges.sortedStably(by: { $0.location > $1.location }) {
            rest = rest.replacingCharacters(in: range, with: "") as NSString
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Where the headings of `chapter` lie in its text: each heading's own
    /// words, at its place, when they are there. A heading the parser made
    /// up for a chapter without one is not in the text, and is left out.
    static func headingRanges(in chapter: Chapter) -> [NSRange] {
        let text = chapter.text as NSString
        return chapter.headings.compactMap { heading in
            let length = (heading.text as NSString).length
            guard length > 0, heading.characterOffset >= 0, heading.characterOffset <= text.length - length else {
                return nil
            }
            let range = NSRange(location: heading.characterOffset, length: length)
            return text.substring(with: range) == heading.text ? range : nil
        }
    }
}

// MARK: - Taking an Edit into the Package

extension TranscriptStore {
    /// What taking an edit of a transcribed audiobook's text did (`takeEdit`).
    struct TakenEdit {
        /// The book as its record holds it now, its audio index carrying the
        /// edited text's layer.
        let committed: Book
        /// The edited text, as a reader shows it.
        let text: TranscriptText
        /// transcript.json as written with the edit: the source the next
        /// check of the text compares with.
        let source: FileFingerprint
    }

    /// Takes the edit `chapters`, content.md as the user saved it, holding
    /// `markdown`, parsed, and fingerprinted as `cache`, as `book`'s
    /// transcript text (FR05): transcript.json takes the edit, laid over its
    /// sentences (`TranscriptEditing`) and marked edited `now`; the book's
    /// audio index takes the text's layer, fingerprinted with the new
    /// transcript.json as its source and the user's content.md as its cache,
    /// so no load writes the text again over the edit; and the record is
    /// saved. content.md itself stays exactly as the user saved it. When the
    /// record cannot take the index, transcript.json is put back as it was.
    ///
    /// Runs inside the storage work of the edit's check, and blocks while it
    /// reads and writes.
    /// - Returns: What was taken; nil when the book's record could not take
    ///   the index now (it is only in the cloud, or the book moved).
    /// - Throws: `TranscriptEditError`, or why a file or the record could
    ///   not be written.
    static func takeEdit(
        _ chapters: [Chapter],
        markdown: String,
        cache: FileFingerprint,
        of book: Book,
        now: Date = Date(),
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        hasher: FingerprintHasher = .md5
    ) throws -> TakenEdit? {
        guard case .found(let transcript) = read(from: book.tmbDirectory) else {
            throw TranscriptEditError.transcriptUnavailable
        }
        var audioIndex = try BookContentAnalysisService.load(book: book).index
        audioIndex.transcript = nil
        if case .changed(let reason) = TranscriptTextLoader.audioCheck(
            of: transcript.audioFiles,
            for: book,
            audioIndex: audioIndex,
            isDataless: isDataless,
            hasher: hasher
        ) {
            throw TranscriptEditError.audioChanged(reason)
        }
        // Whole seconds, as transcript.json keeps its dates.
        let editedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let edit = try TranscriptEditing.apply(
            chapters,
            to: transcript,
            over: audioIndex,
            bookFileName: book.bookFileURL.lastPathComponent,
            editedAt: editedAt
        )

        let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let written = try write(edit.transcript, into: book.tmbDirectory)
        // Puts transcript.json back as it was, when the record does not take
        // the edit: the text it describes is still the book's.
        let restore = { _ = try? write(transcript, into: book.tmbDirectory) }
        guard let stamp = FileStamp(of: transcriptURL) else {
            restore()
            throw TranscriptTextError.notFingerprinted
        }
        let source = FileFingerprint(stamp: stamp, digest: hasher.digestOfData(written))
        let text = TranscriptTextBuilder.Text(
            markdown: markdown,
            chapters: chapters,
            readingIndex: BookContentIndex.build(fromChapters: chapters, format: .markdown),
            sentences: edit.sentences
        )
        let layer = TranscriptTextBuilder.index(
            of: text,
            from: edit.transcript,
            fingerprint: TextCacheFingerprint(source: source, cache: cache)
        )
        var index = audioIndex
        index.transcript = layer
        if let failure = layer.validationFailure(against: index) {
            restore()
            throw TranscriptEditError.unindexable(failure)
        }
        let committed: Book?
        do {
            committed = try LibraryPersistenceService.saveContentAnalysis(for: book, index: index, cacheFormatVersion: nil)
        } catch {
            restore()
            throw error
        }
        guard let committed else {
            restore()
            return nil
        }
        return TakenEdit(committed: committed, text: TranscriptText(chapters: chapters, index: layer), source: source)
    }
}
