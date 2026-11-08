import Foundation

// MARK: - A Podcast's Chapters (FMT25)

/// One chapter of a podcast's chapters file, as TextMouth keeps it.
struct PodcastChapter: Equatable, Sendable {
    /// When the chapter begins, in milliseconds from the start of the
    /// episode's audio.
    var startMilliseconds: Int
    /// The chapter's title on one line, its white space finished as a cue's
    /// text is (`TimedTextCue.plainText`). Empty when the file gave none; a
    /// book then names the chapter by its place
    /// (`PodcastChapters.bookChapters(fileDuration:)`).
    var title: String
}

/// A podcast episode's chapters (Podcasting 2.0, version 1.2.0), as listed in its table of contents.
///
/// A chapters file comes with an episode, from the address its feed gives
/// (`<podcast:chapters>`):
///
///     {"version": "1.2.0", "chapters": [
///         {"startTime": 0, "title": "Intro"},
///         {"startTime": 62.5, "title": "News", "img": "…", "url": "…"}
///     ]}
///
/// TextMouth keeps each chapter's start and title, and nothing else: a
/// chapter's end, picture, link, and place are left, as are the file's other
/// fields, and no address in the file is ever opened. A chapter marked
/// `"toc": false`, as a change of picture or an advertisement's marker is,
/// is not in the table of contents, and is not kept. The chapters are kept
/// beside the episode's audio in a normalized file (`normalizedJSON()`) and
/// become the book's chapters (`bookChapters(fileDuration:)`).
struct PodcastChapters: Equatable, Sendable {
    /// The most chapters a file may hold. A file listing more is refused
    /// before any is read: an episode's table of contents lists dozens of
    /// chapters, and a list of thousands is none a listener could move
    /// through.
    static let maximumChapters = 5_000

    /// The version of the chapters file `normalizedJSON()` writes.
    private static let normalizedVersion = "1.2.0"

    /// The chapters, in the order they begin; chapters that begin together
    /// keep the order the file gives them.
    var chapters: [PodcastChapter]

    /// The chapters `data`, a Podcasting 2.0 chapters file, lists in its
    /// table of contents, in the order they begin.
    ///
    /// A chapter that is not an object, or whose start does not read or lies
    /// past `Transcript.maximumMilliseconds`, is passed over, as is one out
    /// of the table of contents. A start is a number of seconds, given as a
    /// JSON number or as text holding one.
    /// - Throws: `PodcastChaptersError.notChapters` when `data` is not JSON,
    ///   holds no object at its top, or has no list of chapters;
    ///   `.unsupportedVersion` for a major version other than 1;
    ///   `.tooManyChapters` for a list longer than `maximumChapters`; and
    ///   `.noChapters` when no chapter is left.
    static func read(_ data: Data) throws -> PodcastChapters {
        guard let file = FeedJSON.object(in: data) else {
            throw PodcastChaptersError.notChapters
        }
        if let version = PodcastingJSON.unsupportedVersion(of: file) {
            throw PodcastChaptersError.unsupportedVersion(version)
        }
        guard let elements = file["chapters"] as? [Any] else {
            throw PodcastChaptersError.notChapters
        }
        // Counted before any chapter is read, so an overlong list is
        // refused whatever its chapters hold.
        guard elements.count <= maximumChapters else {
            throw PodcastChaptersError.tooManyChapters(limit: maximumChapters)
        }
        let chapters = PodcastingJSON.sortedByStart(elements.compactMap(chapter(from:)), start: \.startMilliseconds)
        guard !chapters.isEmpty else {
            throw PodcastChaptersError.noChapters
        }
        return PodcastChapters(chapters: chapters)
    }

    /// The chapter `element`, one element of the file's list, gives; nil
    /// when it is passed over: not an object, out of the table of contents
    /// (`isOutOfTheContents(_:)`), or with a start that does not read or lies
    /// past `Transcript.maximumMilliseconds`. A title that is missing or not
    /// text is kept as an empty one.
    private static func chapter(from element: Any) -> PodcastChapter? {
        guard let fields = element as? [String: Any],
              !isOutOfTheContents(fields["toc"]),
              let start = PodcastingJSON.milliseconds(fields["startTime"])
        else {
            return nil
        }
        return PodcastChapter(startMilliseconds: start, title: PodcastingJSON.plainText(fields["title"]) ?? "")
    }

    /// Whether a chapter's `toc` field, `value`, leaves it out of the table
    /// of contents: JSON's false, or the text "false" in any letter case, as
    /// a tool that writes every field as text gives it. True, any other
    /// value, or no field at all keeps the chapter in.
    private static func isOutOfTheContents(_ value: Any?) -> Bool {
        if let text = value as? String {
            return text.caseInsensitiveCompare("false") == .orderedSame
        }
        // JSONSerialization reads true and false as numbers; a number that
        // is no truth value (0, say) is not false.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return !number.boolValue
    }

    // MARK: - The File Kept Beside the Audio

    /// A chapters file as `normalizedJSON()` writes it.
    private struct NormalizedFile: Encodable {
        /// One chapter: when it begins, in seconds, and its title.
        struct Chapter: Encodable {
            let startTime: TimeInterval
            let title: String
        }

        let version: String
        let chapters: [Chapter]
    }

    /// The chapters as the file TextMouth keeps beside an episode's audio:
    /// Podcasting 2.0 chapters of version 1.2.0, each with only its start,
    /// in seconds, and its title, the keys sorted so the same chapters
    /// always give the same bytes. Reading it back (`read(_:)`) gives these
    /// chapters again.
    func normalizedJSON() throws -> Data {
        let file = NormalizedFile(
            version: Self.normalizedVersion,
            chapters: chapters.map { chapter in
                NormalizedFile.Chapter(startTime: Transcript.seconds(chapter.startMilliseconds), title: chapter.title)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: - The Book's Chapters

    /// The chapters as a book of one audio file lasting `fileDuration`
    /// seconds takes them, in the shape `AudioPlaybackService.extractChapters`
    /// returns.
    ///
    /// When the last chapter begins more than
    /// `TimedTextLimits.pastTheEndMarginMilliseconds` after the end of the
    /// audio, the file was made for other audio, such as another edition of
    /// the episode, and gives no chapters. Otherwise the chapters are made
    /// by Nero's rules (`NeroChapterReader.bookChapters(from:fileDuration:)`):
    /// in order, a chapter at or past the end and a repeated start dropped,
    /// the first beginning at 0, each lasting until the next, and one without
    /// a title named "Chapter N". A length that is not a finite number above
    /// zero gives none.
    ///
    /// A title is made fit for a heading a listener hears and a braille
    /// display shows first (`headingTitle(_:)`): the file is third-party
    /// data, and one title may hold as much as the whole file may.
    func bookChapters(fileDuration: TimeInterval) -> [(title: String, startTime: TimeInterval, duration: TimeInterval)] {
        // Compared as fractional milliseconds, which never overflow; a length
        // that is no number compares as false, and Nero's rules refuse it.
        let margin = Double(TimedTextLimits.pastTheEndMarginMilliseconds)
        if let latestStart = chapters.map(\.startMilliseconds).max(),
           Double(latestStart) > fileDuration * 1_000 + margin {
            return []
        }
        return NeroChapterReader.bookChapters(
            from: chapters.map {
                NeroChapterReader.Chapter(title: Self.headingTitle($0.title), start: Transcript.seconds($0.startMilliseconds))
            },
            fileDuration: fileDuration
        )
    }

    /// The most characters (Unicode scalars) of a chapter's title a heading
    /// keeps. A title is a line a listener hears when moving by heading and
    /// a braille display shows; an episode's runs to a few dozen characters,
    /// and a file of up to `TimedTextLimits.podcastChaptersBytes` may hold a
    /// single title that long, which the heading list, the index saved in the
    /// package, and the transcript's headings would all carry.
    static let maximumTitleCharacters = 200

    /// `title` as a heading shows it: its control characters (a NUL, say)
    /// removed, cut to `maximumTitleCharacters` at the end of a character the
    /// listener sees as one (so no accent is parted from its letter), with
    /// "…" after what was cut, and empty when nothing in it can be seen or
    /// heard (only invisible characters such as a zero-width space), so a book
    /// names such a chapter by its place ("Chapter N") as it does an untitled
    /// one. A title finished as `PodcastChapter.title` is (one line, its
    /// white space single spaces) stays as it is.
    static func headingTitle(_ title: String) -> String {
        // Control characters are never part of a name; format characters
        // (a joiner in an emoji, a mark that turns text right to left) are.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: title.unicodeScalars.filter { $0.properties.generalCategory != .control })
        guard scalars.contains(where: isVisible) else { return "" }

        // Whole characters are kept while they fit: counting scalars, not
        // characters, bounds a title made of one character with a megabyte
        // of combining marks, which no count of characters would.
        var kept = String.UnicodeScalarView()
        var keptCount = 0
        for character in String(scalars) {
            let width = character.unicodeScalars.count
            if keptCount + width > maximumTitleCharacters {
                // Finished before the mark, so it never follows a space.
                let text = String(kept).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? "" : text + "\u{2026}"
            }
            kept.append(contentsOf: character.unicodeScalars)
            keptCount += width
        }
        return String(kept)
    }

    /// Whether `scalar` can be seen or heard: not white space, not a format
    /// character (a zero-width space, a byte order mark), not a separator.
    /// A letter, mark, number, punctuation, or symbol can.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }
}

// MARK: - Why a Chapters File Is Not Used

/// Why a chapters file is not used; logged, never shown.
enum PodcastChaptersError: Error, Equatable, CustomStringConvertible {
    /// Not JSON, not an object, or no "chapters" array.
    case notChapters
    /// A major version other than 1, as the file gives it, cut to its first
    /// `PodcastingJSON.versionCharacterLimit` characters.
    case unsupportedVersion(String)
    /// No chapter of the list could be used, or every one is out of the
    /// table of contents.
    case noChapters
    /// The list is longer than `PodcastChapters.maximumChapters`: the limit.
    case tooManyChapters(limit: Int)

    /// The reason, worded for the log. It never quotes a title, which is the
    /// episode's text; a version it names is cut short.
    var description: String {
        switch self {
        case .notChapters:
            return "not a chapters file"
        case .unsupportedVersion(let version):
            return "version \(version) is not one TextMouth reads"
        case .noChapters:
            return "it lists no chapter TextMouth can use"
        case .tooManyChapters(let limit):
            return "it lists more than \(limit) chapters"
        }
    }
}
