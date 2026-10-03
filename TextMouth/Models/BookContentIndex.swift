import Foundation

/// Persisted, versioned navigation and statistics derived from a book's parsed
/// content. The full index lives in the package's bookInfo.json; library.json
/// stores only the version and compact totals already exposed by Book.
struct BookContentIndex: Codable, Hashable {
    /// Bump for changes to derived reading text, heading coordinates, metrics, or
    /// the index schema. Existing Markdown can then be reindexed without forcing
    /// another source extraction via MarkdownCacheService.currentCacheVersion.
    static let currentVersion = "1.0.0"

    enum Kind: String, Codable, Hashable {
        case text
        case audio
    }

    enum AudioLayout: String, Codable, Hashable {
        case singleFile
        case multiFile
        case segmented

        /// Whether every chapter names its own audio file. A single-file book
        /// plays the book's file itself, so its chapters name none.
        var namesChapterFiles: Bool { self != .singleFile }
    }

    var version: String
    var kind: Kind
    var format: BookFormat
    var generatedAt: Date
    var totalWordCount: Int
    var totalCharacterCount: Int
    var totalAudioDuration: TimeInterval?
    var audioLayout: AudioLayout?
    var chapters: [BookContentChapterIndex]
    /// The fingerprints of the source and content.md a text book's index was
    /// made from, once a cache write or a verified load has recorded them;
    /// nil for audio and for an index made before fingerprints (TODO T07).
    /// The index carries them so every path that saves an analysis saves
    /// them too (`Book.applyContentAnalysis(_:cacheFormatVersion:)`). They
    /// describe the files, not the counts, so adding them leaves
    /// `currentVersion` as it is.
    var textCacheFingerprint: TextCacheFingerprint? = nil

    var isCurrent: Bool { version == Self.currentVersion }

    func replacingFormat(_ format: BookFormat) -> BookContentIndex {
        var copy = self
        copy.version = Self.currentVersion
        copy.kind = format.isAudio ? .audio : .text
        copy.format = format
        copy.generatedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        return copy
    }

    var allHeadings: [Heading] {
        chapters.flatMap { chapter in
            chapter.headings.map { stored in
                Heading(
                    level: stored.level,
                    text: stored.text,
                    chapterIndex: chapter.chapterIndex,
                    characterOffset: stored.characterOffset
                )
            }
        }
    }

    func chapterStartOffset(_ chapterIndex: Int) -> Int {
        guard chapterIndex > 0 else { return 0 }
        guard chapterIndex < chapters.count else { return totalCharacterCount }
        return chapters[chapterIndex].startCharacterOffset
    }

    func location(forGlobalOffset globalOffset: Int) -> (chapterIndex: Int, localOffset: Int) {
        guard !chapters.isEmpty else { return (0, 0) }
        let clamped = max(0, min(globalOffset, totalCharacterCount))
        if clamped >= totalCharacterCount {
            let last = chapters[chapters.count - 1]
            return (last.chapterIndex, max(0, last.characterCount - 1))
        }

        var low = 0
        var high = chapters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chapters[middle].startCharacterOffset <= clamped {
                low = middle
            } else {
                high = middle - 1
            }
        }

        // Zero-length chapters share a start offset. Advance to the first
        // following chapter that actually contains this coordinate.
        var resolved = low
        while resolved + 1 < chapters.count,
              clamped >= chapters[resolved].startCharacterOffset + chapters[resolved].characterCount {
            resolved += 1
        }
        let chapter = chapters[resolved]
        return (chapter.chapterIndex, max(0, clamped - chapter.startCharacterOffset))
    }

    /// Build the persisted index once, off the main actor, while parsed chapter
    /// strings are already resident. Word splitting never needs to recur in UI
    /// getters after this point.
    static func build(
        from content: DocumentContent,
        format: BookFormat,
        audioFilePaths: [String]? = nil,
        audioSegments: [AudioSegment]? = nil,
        audioBaseURL: URL? = nil
    ) -> BookContentIndex {
        build(
            fromChapters: content.chapters,
            format: format,
            audioFilePaths: audioFilePaths,
            audioSegments: audioSegments,
            audioBaseURL: audioBaseURL
        )
    }

    static func build(
        fromChapters chapters: [Chapter],
        format: BookFormat,
        audioFilePaths: [String]? = nil,
        audioSegments: [AudioSegment]? = nil,
        audioBaseURL: URL? = nil
    ) -> BookContentIndex {
        var cumulativeCharacters = 0
        var totalWords = 0
        let isAudio = format.isAudio
        let layout: AudioLayout? = {
            guard isAudio else { return nil }
            if audioSegments?.isEmpty == false { return .segmented }
            if audioFilePaths?.isEmpty == false { return .multiFile }
            return .singleFile
        }()

        let chapterIndexes = chapters.enumerated().map { chapterIndex, chapter in
            let characterCount = chapter.text.utf16Length
            let wordCount = isAudio ? 0 : chapter.wordCount
            totalWords += wordCount

            let headings = chapter.headings.map { heading in
                // The ID is the one `Heading` derives, so it matches
                // `allHeadings`.
                let offset = indexedHeadingOffset(heading.characterOffset, chapterLength: characterCount)
                return BookContentHeadingIndex(
                    id: Heading(level: heading.level, text: heading.text, chapterIndex: chapterIndex, characterOffset: offset).id,
                    level: heading.level,
                    text: heading.text,
                    characterOffset: offset,
                    globalCharacterOffset: cumulativeCharacters + offset
                )
            }

            let audio: BookContentAudioChapterIndex? = {
                guard isAudio else { return nil }
                let segment = audioSegments.flatMap { chapterIndex < $0.count ? $0[chapterIndex] : nil }
                // A section of several clips records every clip.
                if let segment, segment.clips.count > 1 {
                    return BookContentAudioChapterIndex(severalClipsOf: segment)
                }
                let path = audioFilePaths.flatMap { chapterIndex < $0.count ? $0[chapterIndex] : nil }
                let relativePath: String?
                if let segment {
                    relativePath = segment.file
                } else if let path {
                    relativePath = relativeAudioPath(path, baseURL: audioBaseURL)
                } else {
                    relativePath = nil
                }
                let inferredDuration = Double(characterCount) / ReaderViewModel.audioCharsPerSecond
                let startTime = segment?.startTime ?? 0
                let segmentDuration = segment.map { max(0, $0.endTime - $0.startTime) }
                let resolvedDuration = segmentDuration.flatMap { $0 > 0 ? $0 : nil }
                    ?? inferredDuration
                return BookContentAudioChapterIndex(
                    relativeFilePath: relativePath,
                    startTime: startTime,
                    duration: resolvedDuration
                )
            }()

            let stored = BookContentChapterIndex(
                chapterIndex: chapterIndex,
                title: chapter.title,
                startCharacterOffset: cumulativeCharacters,
                characterCount: characterCount,
                wordCount: wordCount,
                headings: headings,
                audio: audio
            )
            cumulativeCharacters += characterCount
            return stored
        }

        return BookContentIndex(
            version: currentVersion,
            kind: isAudio ? .audio : .text,
            format: format,
            generatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            totalWordCount: totalWords,
            totalCharacterCount: cumulativeCharacters,
            totalAudioDuration: isAudio
                ? chapterIndexes.reduce(0) { $0 + ($1.audio?.duration ?? 0) }
                : nil,
            audioLayout: layout,
            chapters: chapterIndexes
        )
    }

    /// Where the index records a heading that the parser placed at `offset`
    /// in a chapter `chapterLength` UTF-16 code units long: there, kept
    /// inside the chapter. A heading whose label adds no reading text (one
    /// made only of inline HTML, such as "# <br>") can be placed past the end
    /// of its chapter's trimmed text; it is recorded at the chapter's end,
    /// where validation expects every heading to lie. The builder records
    /// offsets through this and alignment compares through it, so the two
    /// always agree about such a heading.
    static func indexedHeadingOffset(_ offset: Int, chapterLength: Int) -> Int {
        min(max(0, offset), chapterLength)
    }

    /// Reconstruct the lightweight placeholder document used by audio playback
    /// without re-reading AVAsset duration and chapter metadata on every open.
    /// Each chapter's count decides how many placeholder characters are
    /// allocated, so a persisted index must pass `validationFailure` first.
    func makeAudioDocumentContent(title: String, author: String) -> DocumentContent? {
        guard isCurrent, kind == .audio else { return nil }
        let restoredChapters = chapters.map { stored in
            Chapter(
                title: stored.title,
                text: String(repeating: " ", count: max(1, stored.characterCount)),
                headings: stored.headings.map {
                    Heading(
                        level: $0.level,
                        text: $0.text,
                        chapterIndex: stored.chapterIndex,
                        characterOffset: $0.characterOffset
                    )
                }
            )
        }
        return DocumentContent(
            title: title,
            author: author,
            chapters: restoredChapters,
            contentIndex: self
        )
    }

    /// One absolute audio file path per chapter, resolved against `bookURL`,
    /// for layouts whose chapters name their own files; nil for a single-file
    /// book. A chapter of several clips gives the file it starts in, its
    /// first clip's, as the parser lists it. All or nothing: if any chapter
    /// names no file the result is nil, because a shorter list would shift
    /// every later chapter onto the file of the chapter before it.
    func resolvedAudioFilePaths(relativeTo bookURL: URL) -> [String]? {
        guard audioLayout?.namesChapterFiles == true else { return nil }
        let relativePaths = chapters.compactMap(\.audioFilePath)
        guard relativePaths.count == chapters.count else { return nil }
        return relativePaths.map { bookURL.appendingPathComponent($0).path }
    }

    /// The segments a segmented book plays, one per chapter with every clip
    /// it plays, or nil for any other layout or when a chapter or any of its
    /// clips lacks its timing or file (again all or nothing, so segments
    /// never shift onto the wrong chapter). Each clip ends at its start plus
    /// its length.
    func restoredAudioSegments() -> [AudioSegment]? {
        guard audioLayout == .segmented else { return nil }
        let restored = chapters.compactMap { chapter -> AudioSegment? in
            guard let audio = chapter.audio, let file = chapter.audioFilePath else { return nil }
            // A chapter without a clip list plays one clip, which its own
            // fields describe, as every chapter did before chapters could
            // play several.
            guard let clips = audio.clips else {
                return AudioSegment(
                    title: chapter.title,
                    file: file,
                    startTime: audio.startTime,
                    endTime: audio.startTime + audio.duration
                )
            }
            let restoredClips = clips.compactMap { clip in
                clip.audioFilePath.map {
                    AudioClip(file: $0, startTime: clip.startTime, endTime: clip.startTime + clip.duration)
                }
            }
            // A clip without its file loses the whole chapter, not just
            // that clip; an empty list restores no section either.
            guard restoredClips.count == clips.count else { return nil }
            return AudioSegment(title: chapter.title, clips: restoredClips)
        }
        return restored.count == chapters.count ? restored : nil
    }

    /// `path` relative to `baseURL`, as persisted for a multi-file book, or
    /// only the file's name when it lies outside that folder. Canonical
    /// locations are compared first, as validation compares them: the
    /// directory enumerator reports files through the folder's resolved
    /// location (/private/var for /var, or a linked folder's destination),
    /// while `baseURL` keeps the book's own spelling. Comparing spellings
    /// alone recorded a linked folder's "Disc 2/03.wav" as "03.wav". Paths
    /// that do not exist, as in some tests, are compared as spelled.
    private static func relativeAudioPath(_ path: String, baseURL: URL?) -> String {
        let fileURL = URL(fileURLWithPath: path)
        guard let baseURL else { return fileURL.lastPathComponent }
        if let folder = canonicalPath(of: baseURL.path),
           let file = canonicalPath(of: path),
           let relative = relativePath(of: file, inside: folder) {
            return relative
        }
        return relativePath(of: fileURL.standardizedFileURL.path, inside: baseURL.standardizedFileURL.path)
            ?? fileURL.lastPathComponent
    }

    /// `path` without its leading `folder`, or nil when it is not inside it.
    /// The builder records paths with it and validation's containment check
    /// tests them with it, so both draw the folder's boundary identically.
    private static func relativePath(of path: String, inside folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}

// MARK: - Validation

extension BookContentIndex {
    /// Most UTF-16 code units one chapter, or a whole book, may claim.
    ///
    /// Opening an audiobook from its index allocates a placeholder string of
    /// each chapter's length, so a damaged count in bookInfo.json could
    /// otherwise allocate gigabytes. Real books stay far below the cap: a
    /// 50 MB plain-text book holds at most 50 million code units (one per
    /// byte of ASCII, fewer for any other script), and a 200-hour audiobook
    /// at `ReaderViewModel.audioCharsPerSecond` (10) needs 7.2 million
    /// placeholder characters. Twice the larger yardstick leaves room for
    /// any real book while bounding a placeholder allocation near 100 MB.
    static let maximumCharacterCount = 100_000_000

    /// The heading levels HTML and Markdown define, the only ones parsers
    /// produce.
    static let headingLevels = 1...6

    /// Largest difference tolerated between `totalAudioDuration` and the sum
    /// of the chapter durations. The builder sums the durations in chapter
    /// order, as validation does, and JSON stores each value exactly, so a
    /// sound index matches to the bit; one millisecond allows for any other
    /// rounding while staying far below anything a listener could notice.
    static let audioDurationTolerance: TimeInterval = 0.001

    /// Whether this index can be trusted for a book of `format`: true exactly
    /// when `validationFailure(for:audioBaseURL:)` finds nothing wrong.
    func isValid(for format: BookFormat, audioBaseURL: URL?) -> Bool {
        validationFailure(for: format, audioBaseURL: audioBaseURL) == nil
    }

    /// Why this persisted index cannot be trusted for a book of `format`, or
    /// nil when it can. The reason names the first offending field as
    /// bookInfo.json spells it, for example
    /// `chapters[2].startCharacterOffset is 40, expected 52`.
    ///
    /// Opening a book from its index skips parsing, so everything the reader
    /// derives from the index must hold here: chapters numbered in order,
    /// offsets that are the running sums of their lengths, matching totals,
    /// headings inside their chapters, counts within
    /// `maximumCharacterCount`, finite audio timing, and audio paths that
    /// stay inside the book's folder and, where they exist, name regular
    /// files. A missing audio file or folder is not a failure here: playback
    /// reports it for the chapter that needs it. Each chapter and heading is
    /// read once and each distinct audio file looked up once, so the cost is
    /// linear in the size of the index.
    ///
    /// - Parameter audioBaseURL: The folder the chapters' relative audio
    ///   paths resolve against: the book's file path, which for a multi-file
    ///   or segmented audiobook is its audio folder. With nil, the checks
    ///   that need the file system (that what exists of each path stays
    ///   inside the folder once symbolic links are resolved, and is a
    ///   regular file) are skipped, while each path's own form is still
    ///   checked.
    func validationFailure(for format: BookFormat, audioBaseURL: URL?) -> String? {
        identityFailure(for: format)
            ?? chapterFailure()
            ?? (kind == .audio ? audioFailure(audioBaseURL: audioBaseURL) : textFailure())
    }

    /// Why this index cannot describe `chapters`, the reading text it is
    /// about to be paired with, or nil when it can. A text book's index and
    /// its content.md are written separately, so a sound index can still
    /// describe other text, and matching lengths alone do not prove it does:
    /// text edited to the same length can move, rename, add, or drop a
    /// heading, or join and split words. Both must hold the same number of
    /// chapters, and each chapter must have the length, the headings (the
    /// same number, each at the same offset with the same label and level),
    /// and the word count the index records, with the totals to match.
    ///
    /// The reason names the first mismatch by the field bookInfo.json spells,
    /// for example
    /// `chapters[1].characterCount is 15, but the reading text holds 16`.
    /// The debug log records the reason (`CONTENT_INDEX_REJECTED`), and the
    /// book's text never goes there (`DiagnosticLog`), so a relabeled heading
    /// is named by its place, with where the two labels first differ and how
    /// long each is, never by either label:
    /// `chapters[1].headings[0].text differs from the reading text's label at UTF-16 offset 0 (lengths 5 and 6)`.
    ///
    /// - Parameter countingWords: Whether to count each chapter's words, the
    ///   one comparison that reads every character of the text (tens of
    ///   milliseconds for a long book). Pass false only when the index is
    ///   known to have been measured from these very chapters, as a load
    ///   knows from the fingerprints the index records; every other
    ///   comparison still runs.
    func alignmentFailure(with chapters: [Chapter], countingWords: Bool = true) -> String? {
        guard self.chapters.count == chapters.count else {
            return "chapters has \(self.chapters.count) entries, but the reading text has \(chapters.count)"
        }
        var characters = 0
        var words = 0
        for (position, (stored, chapter)) in zip(self.chapters, chapters).enumerated() {
            let field = "chapters[\(position)]"
            let length = chapter.text.utf16Length
            if stored.characterCount != length {
                return "\(field).characterCount is \(stored.characterCount), but the reading text holds \(length)"
            }
            if let failure = headingAlignmentFailure(of: stored, with: chapter, field: field) {
                return failure
            }
            if countingWords {
                let wordCount = chapter.wordCount
                if stored.wordCount != wordCount {
                    return "\(field).wordCount is \(stored.wordCount), but the reading text holds \(wordCount)"
                }
                words += wordCount
            }
            characters += length
        }
        if totalCharacterCount != characters {
            return "totalCharacterCount is \(totalCharacterCount), but the reading text holds \(characters)"
        }
        if countingWords, totalWordCount != words {
            return "totalWordCount is \(totalWordCount), but the reading text holds \(words)"
        }
        return nil
    }

    /// Why `stored`, the index's entry for one chapter, does not list the
    /// headings of `chapter`, its reading text, or nil when it does: the
    /// same number of headings, each at the offset the builder would record
    /// (`indexedHeadingOffset`), with the same label and level. `field` names
    /// the chapter in reasons, and a label that differs is described by
    /// where it first differs and by the two labels' lengths, never by its
    /// words. Called once the lengths match.
    private func headingAlignmentFailure(
        of stored: BookContentChapterIndex,
        with chapter: Chapter,
        field: String
    ) -> String? {
        guard stored.headings.count == chapter.headings.count else {
            return "\(field).headings has \(stored.headings.count) entries, but the reading text has \(chapter.headings.count)"
        }
        for (position, (storedHeading, heading)) in zip(stored.headings, chapter.headings).enumerated() {
            let field = "\(field).headings[\(position)]"
            let offset = Self.indexedHeadingOffset(heading.characterOffset, chapterLength: stored.characterCount)
            if storedHeading.characterOffset != offset {
                return "\(field).characterOffset is \(storedHeading.characterOffset), but the reading text has it at \(offset)"
            }
            if storedHeading.text != heading.text {
                // A label is the book's text, which the debug log never
                // holds: say where the two part and how long each is.
                let difference = Self.firstDifferingUTF16Offset(storedHeading.text, heading.text)
                return "\(field).text differs from the reading text's label at UTF-16 offset \(difference) "
                    + "(lengths \(storedHeading.text.utf16Length) and \(heading.text.utf16Length))"
            }
            if storedHeading.level != heading.level {
                return "\(field).level is \(storedHeading.level), but the reading text has \(heading.level)"
            }
        }
        return nil
    }

    /// The UTF-16 offset at which `label` and `other` first differ: their
    /// first code unit that disagrees, or the shorter one's length when it
    /// is the start of the other. Labels that differ as strings always
    /// differ somewhere in their code units.
    private static func firstDifferingUTF16Offset(_ label: String, _ other: String) -> Int {
        zip(label.utf16, other.utf16).prefix(while: { $0.0 == $0.1 }).count
    }

    /// Whether the current builder made this index for a book of `format`.
    private func identityFailure(for format: BookFormat) -> String? {
        if !isCurrent {
            return "version \(String(reflecting: version)) is not the current \(String(reflecting: Self.currentVersion))"
        }
        if self.format != format {
            return "format \(self.format.rawValue) does not match the book's format \(format.rawValue)"
        }
        if kind != (format.isAudio ? .audio : .text) {
            return "kind \(kind.rawValue) does not match format \(format.rawValue)"
        }
        return nil
    }

    /// Chapter numbering, lengths, running offsets, headings, and totals: the
    /// structure every position calculation relies on. Each count is checked
    /// against the cap before it is added, and the running sum after, so the
    /// sums stay far from overflow. Ranges are formed only from counts
    /// already known to be non-negative, because a reversed range traps.
    private func chapterFailure() -> String? {
        guard !chapters.isEmpty else { return "chapters is empty" }
        var characters = 0
        var words = 0
        for (position, chapter) in chapters.enumerated() {
            let field = "chapters[\(position)]"
            if chapter.chapterIndex != position {
                return "\(field).chapterIndex is \(chapter.chapterIndex), expected \(position)"
            }
            if chapter.characterCount < 0 {
                return "\(field).characterCount is \(chapter.characterCount), below 0"
            }
            if chapter.characterCount > Self.maximumCharacterCount {
                return "\(field).characterCount is \(chapter.characterCount), above the limit of \(Self.maximumCharacterCount)"
            }
            // Every word holds at least one character, so the character
            // count also bounds the word count (and the word total).
            if !(0...chapter.characterCount).contains(chapter.wordCount) {
                return "\(field).wordCount is \(chapter.wordCount), outside 0 through \(chapter.characterCount)"
            }
            if chapter.startCharacterOffset != characters {
                return "\(field).startCharacterOffset is \(chapter.startCharacterOffset), expected \(characters)"
            }
            if let failure = headingFailure(in: chapter, field: field) {
                return failure
            }
            characters += chapter.characterCount
            words += chapter.wordCount
            if characters > Self.maximumCharacterCount {
                return "the chapters hold \(characters) characters, above the limit of \(Self.maximumCharacterCount)"
            }
        }
        if totalCharacterCount != characters {
            return "totalCharacterCount is \(totalCharacterCount), expected \(characters)"
        }
        // Audio chapters hold placeholder spaces, which count as no words.
        if kind == .text, totalWordCount != words {
            return "totalWordCount is \(totalWordCount), expected \(words)"
        }
        return nil
    }

    /// Each heading's level and identity, and its place within `chapter`:
    /// inside the chapter's text, in reading order, and at the global offset
    /// its chapter's start implies. `field` names the chapter in reasons.
    private func headingFailure(in chapter: BookContentChapterIndex, field: String) -> String? {
        var previousOffset = 0
        for (position, heading) in chapter.headings.enumerated() {
            let field = "\(field).headings[\(position)]"
            if !Self.headingLevels.contains(heading.level) {
                return "\(field).level is \(heading.level), outside \(Self.headingLevels.lowerBound) through \(Self.headingLevels.upperBound)"
            }
            if heading.id.isEmpty {
                return "\(field).id is empty"
            }
            // A heading may sit at the very end of its chapter, but not past it.
            if !(0...chapter.characterCount).contains(heading.characterOffset) {
                return "\(field).characterOffset is \(heading.characterOffset), outside 0 through \(chapter.characterCount)"
            }
            if heading.characterOffset < previousOffset {
                return "\(field).characterOffset is \(heading.characterOffset), before the previous heading's \(previousOffset)"
            }
            let expectedGlobalOffset = chapter.startCharacterOffset + heading.characterOffset
            if heading.globalCharacterOffset != expectedGlobalOffset {
                return "\(field).globalCharacterOffset is \(heading.globalCharacterOffset), expected \(expectedGlobalOffset)"
            }
            previousOffset = heading.characterOffset
        }
        return nil
    }

    /// A text index describes words alone. Audio timing or paths in one did
    /// not come from the builder, which writes none for text.
    private func textFailure() -> String? {
        if audioLayout != nil {
            return "audioLayout is present in a text index"
        }
        if totalAudioDuration != nil {
            return "totalAudioDuration is present in a text index"
        }
        if let position = chapters.firstIndex(where: { $0.audio != nil }) {
            return "chapters[\(position)].audio is present in a text index"
        }
        return nil
    }

    /// The audio layout, each chapter's placeholder length, timing, (for
    /// layouts that name a file per chapter) file, and clips, and the
    /// duration total. `audioBaseURL` is the folder those files must stay
    /// inside, as for `validationFailure(for:audioBaseURL:)`.
    private func audioFailure(audioBaseURL: URL?) -> String? {
        guard let audioLayout else { return "audioLayout is missing" }
        var files = audioLayout.namesChapterFiles ? AudioFileCheck(folder: audioBaseURL) : nil
        var duration: TimeInterval = 0
        for (position, chapter) in chapters.enumerated() {
            let field = "chapters[\(position)]"
            // The parser gives every audio chapter at least one placeholder
            // character, and playback restores exactly that many.
            if chapter.characterCount == 0 {
                return "\(field).characterCount is 0, but an audio chapter holds at least 1 placeholder character"
            }
            guard let audio = chapter.audio else {
                return "\(field).audio is missing"
            }
            if let failure = Self.timeFailure(audio.startTime, field: "\(field).audio.startTime")
                ?? Self.timeFailure(audio.duration, field: "\(field).audio.duration") {
                return failure
            }
            if let failure = files?.failure(for: chapter.audioFilePath, field: "\(field).audio.relativeFilePath") {
                return failure
            }
            if let clips = audio.clips,
               let failure = clipFailure(clips, of: audio, layout: audioLayout, field: "\(field).audio", files: &files) {
                return failure
            }
            duration += audio.duration
        }
        guard let totalAudioDuration else {
            return "totalAudioDuration is missing"
        }
        // A NaN total fails `isFinite`; comparing it would always pass.
        if !totalAudioDuration.isFinite || abs(totalAudioDuration - duration) > Self.audioDurationTolerance {
            return "totalAudioDuration is \(totalAudioDuration), expected \(duration)"
        }
        return nil
    }

    /// Why `clips`, the clips a chapter whose audio is `audio` plays one
    /// after another, cannot be trusted, or nil when they can. `field` names
    /// the chapter's audio in reasons, and `files` checks each clip's file
    /// exactly as the chapter's own file is checked.
    ///
    /// Only a segmented book's chapters play clips, and a list names at
    /// least one. Every clip has a finite start, 0 or more, and a finite
    /// length of more than 0: a clip is restored as ending at its start plus
    /// its length, and a clip ending at 0 would play its whole file. The
    /// chapter's own fields describe the whole chapter, as they did before
    /// chapters played several clips: the file and start of its first clip,
    /// and a length equal to its clips' together.
    private func clipFailure(
        _ clips: [BookContentAudioClipIndex],
        of audio: BookContentAudioChapterIndex,
        layout: AudioLayout,
        field: String,
        files: inout AudioFileCheck?
    ) -> String? {
        guard layout == .segmented else {
            return "\(field).clips is present in a \(layout.rawValue) index"
        }
        guard let first = clips.first else {
            return "\(field).clips is empty"
        }
        var duration: TimeInterval = 0
        for (number, clip) in clips.enumerated() {
            let clipField = "\(field).clips[\(number)]"
            if let failure = Self.timeFailure(clip.startTime, field: "\(clipField).startTime")
                ?? Self.timeFailure(clip.duration, field: "\(clipField).duration") {
                return failure
            }
            if clip.duration == 0 {
                return "\(clipField).duration is 0.0, but every clip a chapter plays lasts some time"
            }
            if let failure = files?.failure(for: clip.audioFilePath, field: "\(clipField).relativeFilePath") {
                return failure
            }
            duration += clip.duration
        }
        // Both paths were checked above, so neither is missing here.
        if audio.relativeFilePath != first.relativeFilePath {
            return "\(field).relativeFilePath is \(String(reflecting: audio.relativeFilePath ?? "")), "
                + "but its first clip's is \(String(reflecting: first.relativeFilePath ?? ""))"
        }
        if audio.startTime != first.startTime {
            return "\(field).startTime is \(audio.startTime), but its first clip's is \(first.startTime)"
        }
        if abs(audio.duration - duration) > Self.audioDurationTolerance {
            return "\(field).duration is \(audio.duration), expected \(duration), its clips' together"
        }
        return nil
    }

    /// Why `seconds`, a start time or duration, is unusable: NaN, infinite,
    /// or negative. Nil when it is a finite, non-negative number of seconds.
    private static func timeFailure(_ seconds: TimeInterval, field: String) -> String? {
        if seconds.isFinite && seconds >= 0 {
            return nil
        }
        return "\(field) is \(seconds), expected a finite number of seconds, 0 or more"
    }

    /// Checks the audio file each chapter names: first the path's own form,
    /// then, given the folder the paths resolve against, whatever of the
    /// path exists on disk. What exists must stay inside that folder once
    /// every symbolic link is resolved, and a path that exists in full must
    /// name a regular file. A file that does not exist, like a folder that
    /// does not exist, is no reason to distrust the index: playback reports
    /// the missing file and offers Retry, where analyzing the book again
    /// would silently drop its chapter and shift every later one. Paths
    /// already checked are remembered, so a file that many segments share
    /// is looked up only once.
    private struct AudioFileCheck {
        /// The folder the paths resolve against; nil checks only their form.
        private let folder: URL?
        /// The folder's canonical path, or nil when the folder does not
        /// exist, which leaves nothing of any path on disk to check.
        private let canonicalFolder: String?
        /// Relative paths already checked and found acceptable.
        private var checkedPaths: Set<String> = []

        init(folder: URL?) {
            self.folder = folder
            canonicalFolder = folder.flatMap { BookContentIndex.canonicalPath(of: $0.path) }
        }

        /// Why `path`, a chapter's audio file relative to the folder, cannot
        /// be trusted, or nil when it can. `field` names the path in reasons,
        /// which are, in the order checked: the path is missing from the
        /// index, is absolute, contains a ".." component, resolves outside
        /// the audio folder, or is not a regular file. The last two apply
        /// only to what exists on disk.
        mutating func failure(for path: String?, field: String) -> String? {
            guard let path else {
                return "\(field) is missing"
            }
            let quotedPath = String(reflecting: path)
            let components = path.split(separator: "/")
            if path.hasPrefix("/") {
                return "\(field) \(quotedPath) is absolute"
            }
            if components.contains("..") {
                return "\(field) \(quotedPath) contains a \"..\" component"
            }
            guard let folder, let canonicalFolder, !checkedPaths.contains(path) else { return nil }
            // Resolve the deepest part of the path that exists, starting with
            // the whole path. A missing file, or a missing subfolder on the
            // way to it, only shortens that part; so does a broken symbolic
            // link, which playback also reports as a missing file.
            for depth in stride(from: components.count, through: 1, by: -1) {
                let existingPart = components.prefix(depth).joined(separator: "/")
                guard let canonical = BookContentIndex.canonicalPath(
                    of: folder.appendingPathComponent(existingPart).path
                ) else { continue }
                // A symbolic link inside the folder can point anywhere on disk.
                guard Self.isWithin(canonicalFolder, canonical) else {
                    return "\(field) \(quotedPath) resolves outside the audio folder"
                }
                if depth == components.count, !Self.isRegularFile(atPath: canonical) {
                    return "\(field) \(quotedPath) is not a regular file"
                }
                break
            }
            checkedPaths.insert(path)
            return nil
        }

        /// Whether `canonical`, a resolved path, is `canonicalFolder` itself
        /// or lies inside it.
        private static func isWithin(_ canonicalFolder: String, _ canonical: String) -> Bool {
            canonical == canonicalFolder
                || BookContentIndex.relativePath(of: canonical, inside: canonicalFolder) != nil
        }

        /// Whether `path`, already canonical, names a regular file rather
        /// than a folder, a named pipe, or a device.
        private static func isRegularFile(atPath path: String) -> Bool {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return attributes?[.type] as? FileAttributeType == .typeRegular
        }
    }

    /// The absolute path of an existing file or folder with every symbolic
    /// link, ".", and ".." resolved, as realpath(3) gives it, or nil when
    /// nothing exists there. Validation and the builder both compare folders
    /// and files through this, so spellings such as /var and /private/var,
    /// or a linked folder and its destination, agree.
    fileprivate static func canonicalPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct BookContentChapterIndex: Codable, Hashable {
    var chapterIndex: Int
    var title: String
    var startCharacterOffset: Int
    var characterCount: Int
    var wordCount: Int
    var headings: [BookContentHeadingIndex]
    var audio: BookContentAudioChapterIndex?

    /// The audio file this chapter plays, relative to the book's audio
    /// folder, or nil when it names none. An empty path names no file either.
    var audioFilePath: String? {
        guard let path = audio?.relativeFilePath, !path.isEmpty else { return nil }
        return path
    }
}

struct BookContentHeadingIndex: Codable, Hashable {
    var id: String
    var level: Int
    var text: String
    var characterOffset: Int
    var globalCharacterOffset: Int
}

/// Where an audio chapter's sound comes from. For a chapter that plays
/// several clips (a DAISY heading whose narration continues into other
/// files), `clips` lists them all and the other fields describe the whole
/// chapter: where it starts and how long it lasts.
struct BookContentAudioChapterIndex: Codable, Hashable {
    /// The file the chapter starts in, relative to the book's audio folder:
    /// its first clip's file. Nil for a single-file book, whose chapters
    /// play the book's own file.
    var relativeFilePath: String?
    /// Where the chapter starts in that file, in seconds.
    var startTime: TimeInterval
    /// How long the chapter plays, in seconds: its clips' lengths together
    /// for a chapter of several clips.
    var duration: TimeInterval
    /// Every clip the chapter plays, in order, for a chapter of several
    /// clips. Nil for a chapter of one clip, which the fields above
    /// describe, as in every index written before chapters could play
    /// several; such indexes stay current and need no rebuilding.
    var clips: [BookContentAudioClipIndex]? = nil
}

extension BookContentAudioChapterIndex {
    /// The entry for `segment`, a section of several clips: every clip
    /// with its length, and the chapter starting where its first clip does
    /// and lasting as long as its clips together. Each clip must have an
    /// end, as `AudioBookParser` gives every clip of such a section; one
    /// without would be recorded as lasting no time.
    init(severalClipsOf segment: AudioSegment) {
        let clips = segment.clips.map { clip in
            BookContentAudioClipIndex(
                relativeFilePath: clip.file,
                startTime: clip.startTime,
                duration: max(0, clip.endTime - clip.startTime)
            )
        }
        self.init(
            relativeFilePath: segment.file,
            startTime: segment.startTime,
            duration: clips.reduce(0) { $0 + $1.duration },
            clips: clips
        )
    }
}

/// One clip of an audio chapter that plays several: a stretch of one file.
struct BookContentAudioClipIndex: Codable, Hashable {
    /// The clip's file, relative to the book's audio folder.
    var relativeFilePath: String?
    /// Where the clip starts in its file, in seconds.
    var startTime: TimeInterval
    /// How long the clip plays, in seconds.
    var duration: TimeInterval

    /// The clip's file, or nil when it names none. An empty path names no
    /// file either, as for a chapter's own path.
    var audioFilePath: String? {
        guard let relativeFilePath, !relativeFilePath.isEmpty else { return nil }
        return relativeFilePath
    }
}
