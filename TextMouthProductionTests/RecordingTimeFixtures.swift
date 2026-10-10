import XCTest
@testable import TextMouth

/// Books for the tests of P08's clock (`PlaceClock`) and the surfaces that
/// name places by it: audiobooks of each layout and a text book, each with
/// its content index built the way the app builds it, from placeholders the
/// way the parser makes them. No audio file is written and nothing plays.
enum RecordingTimeFixtures {
    /// The four ways an audiobook's chapters are laid out.
    enum Layout: CaseIterable {
        /// One file, one chapter.
        case oneFile
        /// One file with chapter marks.
        case chapterMarks
        /// A file per chapter.
        case filePerChapter
        /// DAISY sections, one of several clips in several files and one
        /// shorter than a second.
        case daisyClips
    }

    /// Thirty chapter lengths, in seconds, between fifteen and twenty-five
    /// minutes, none of them on a tenth of a second, as measured audio is.
    static let thirtyDurations: [TimeInterval] = (0..<30).map { number in
        900 + Double((number * 389) % 600) + 0.0371 * Double(number % 9 + 1)
    }

    /// The length of the one-file book: 9:41:07.4.
    static let oneFileDuration: TimeInterval = 34_867.4

    /// The chapters of a one-file book whose last chapter ends on a whole
    /// second (REV14): 900.2 seconds (its placeholder drops the 0.05), then
    /// exactly 25:03. The Headings sheet once showed the last as 25:02,
    /// measured to the book's last unit, a tenth short of its end, and
    /// subtracting the chapters' times leaves 1502.9999999999998.
    static let wholeSecondLastChapter: [TimeInterval] = [900.25, 1_503]

    /// Where the DAISY book's section shorter than a second is.
    static let shortSectionIndex = 2

    /// The content of an audiobook laid out as `layout`, with its index.
    static func audioContent(_ layout: Layout) throws -> DocumentContent {
        let chapters: [Chapter]
        let index: BookContentIndex
        switch layout {
        case .oneFile:
            return oneFileContent(lasting: [oneFileDuration])
        case .chapterMarks:
            return oneFileContent(lasting: thirtyDurations)
        case .filePerChapter:
            chapters = audioChapters(lasting: thirtyDurations)
            let folder = URL(fileURLWithPath: "/tmp/RecordingTimeFixtures-files", isDirectory: true)
            index = BookContentIndex.build(
                fromChapters: chapters,
                format: .audio,
                audioFilePaths: chapters.indices.map { folder.appendingPathComponent("\($0 + 1).mp3").path },
                audioBaseURL: folder
            )
        case .daisyClips:
            let sections = try daisySections()
            chapters = sections.chapters
            index = BookContentIndex.build(
                fromChapters: chapters,
                format: .audio,
                audioFilePaths: sections.segments.map { "/tmp/RecordingTimeFixtures-daisy/\($0.file)" },
                audioSegments: sections.segments,
                audioBaseURL: URL(fileURLWithPath: "/tmp/RecordingTimeFixtures-daisy", isDirectory: true)
            )
        }
        return DocumentContent(title: "Recording", author: "", chapters: chapters, contentIndex: index)
    }

    /// The content of an audiobook of one file, with its index: one chapter
    /// for each of `durations`, as its chapter marks make them, or one for
    /// a file without marks.
    static func oneFileContent(lasting durations: [TimeInterval]) -> DocumentContent {
        let chapters = audioChapters(lasting: durations)
        let index = BookContentIndex.build(fromChapters: chapters, format: .audio)
        return DocumentContent(title: "Recording", author: "", chapters: chapters, contentIndex: index)
    }

    /// The chapters the parser makes of audio lasting `durations`: a
    /// placeholder of ten characters a second, its fraction dropped
    /// (`AudioBookParser.placeholderLength(for:)`), each opening with its
    /// heading. A DAISY section's placeholder holds at least a second
    /// (`atLeastASecond`), as `parseSegmentedAudio` makes it.
    static func audioChapters(lasting durations: [TimeInterval], atLeastASecond: Bool = false) -> [Chapter] {
        durations.enumerated().map { chapterIndex, duration in
            let title = "Part \(chapterIndex + 1)"
            let length = AudioBookParser.placeholderLength(for: atLeastASecond ? max(1, duration) : duration)
            return Chapter(
                title: title,
                text: String(repeating: " ", count: length),
                headings: [Heading(level: 1, text: title, chapterIndex: chapterIndex, characterOffset: 0)]
            )
        }
    }

    /// A DAISY book's sections as the parser makes them, with the sections
    /// themselves: an opening clip; a section of three clips in three
    /// files; a section of 0.57 seconds, whose placeholder holds a second;
    /// then forty sections of one clip each, each between 0.05 and 0.1
    /// seconds past a tenth, so their placeholders fall behind their clips
    /// by about 2.7 seconds in all.
    static func daisySections() throws -> (chapters: [Chapter], segments: [AudioSegment]) {
        let threeFiles = try XCTUnwrap(AudioSegment(title: "Three Files", clips: [
            AudioClip(file: "a.mp3", startTime: 0, endTime: 12.33),
            AudioClip(file: "b.mp3", startTime: 0, endTime: 7.91),
            AudioClip(file: "c.mp3", startTime: 0, endTime: 4.05),
        ]))
        var segments = [
            AudioSegment(title: "Opening", file: "intro.mp3", startTime: 0, endTime: 3.47),
            threeFiles,
            AudioSegment(title: "Short", file: "c.mp3", startTime: 4.05, endTime: 4.62),
        ]
        for number in 0..<40 {
            let start = Double(number) * 70
            segments.append(AudioSegment(
                title: "Section \(number + 1)",
                file: "long.mp3",
                startTime: start,
                endTime: start + 31.25 + 0.0061 * Double(number % 7 + 1)
            ))
        }
        let durations = segments.map { $0.clips.reduce(0) { $0 + ($1.endTime - $1.startTime) } }
        var chapters = audioChapters(lasting: durations, atLeastASecond: true)
        for chapterIndex in chapters.indices {
            chapters[chapterIndex].title = segments[chapterIndex].title
            chapters[chapterIndex].headings = [
                Heading(level: 1, text: segments[chapterIndex].title, chapterIndex: chapterIndex, characterOffset: 0),
            ]
        }
        return (chapters, segments)
    }

    /// A text book of three chapters, each with a heading at its start and
    /// another halfway through, as a text book's content is indexed.
    static func textContent() -> DocumentContent {
        let sentence = "The ferry crossed at dawn while the gulls argued over the nets. "
        return DocumentContent(
            title: "Crossing",
            author: "",
            chapters: (0..<3).map { chapterIndex in
                let text = String(repeating: sentence, count: 40 + chapterIndex * 13)
                return Chapter(
                    title: "Chapter \(chapterIndex + 1)",
                    text: text,
                    headings: [
                        Heading(level: 1, text: "Chapter \(chapterIndex + 1)", chapterIndex: chapterIndex, characterOffset: 0),
                        Heading(
                            level: 2,
                            text: "Midway \(chapterIndex + 1)",
                            chapterIndex: chapterIndex,
                            characterOffset: text.utf16.count / 2
                        ),
                    ]
                )
            }
        )
    }

    /// A reader for a book of `format` whose source does not exist, so its
    /// background load fails harmlessly and the test assigns its content;
    /// backed by a library of its own and `settings`, or settings without
    /// services. A test that changes a setting passes settings on
    /// preferences of its own. The caller closes the reader.
    @MainActor
    static func makeReader(format: BookFormat, settings: SettingsViewModel? = nil) -> ReaderViewModel {
        let book = Book(
            title: "Place Clock",
            format: format,
            filePath: "/tmp/\(UUID().uuidString)-place-clock",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings ?? SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
    }

    /// Places through a book's clock: the start, and in about every seventh
    /// chapter a third and two thirds of the way through, never at a
    /// chapter's end, which is the next chapter's start, nor past a DAISY
    /// section's clips, which all name the section's end.
    static func samplePlaces(on clock: PlaceClock) -> [PlaceClock.Place] {
        var places = [PlaceClock.Place(chapterIndex: 0, characterOffset: 0)]
        for chapterIndex in Swift.stride(from: 0, to: clock.chapterLengths.count, by: 7) {
            let clipUnits = Int(clock.chapterDurations[chapterIndex] * clock.unitsPerSecond)
            let usable = min(clock.chapterLengths[chapterIndex], clipUnits)
            for offset in [usable / 3, usable * 2 / 3] where offset > 0 {
                places.append(PlaceClock.Place(chapterIndex: chapterIndex, characterOffset: offset))
            }
        }
        return places
    }

    /// A heading position, "Heading `number` of `count`", in a book of
    /// `count` headings at the starts of chapters, for the summaries'
    /// formatters.
    static func headingPosition(number: Int, of count: Int) -> HeadingPosition {
        let headings = (0..<count).map { Heading(level: 1, text: "Part \($0 + 1)", chapterIndex: $0, characterOffset: 0) }
        return HeadingPosition(in: headings, chapterIndex: number - 1, characterOffset: 0)
    }

    /// The time a surface shows, read back as Go to Time reads it; nil when
    /// it cannot be read, which the caller reports.
    static func typedBack(_ shown: String) -> TimeInterval? {
        guard case .seconds(let seconds) = TimeEntry.reading(shown) else { return nil }
        return seconds
    }
}
