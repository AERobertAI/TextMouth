import XCTest
@testable import TextMouth

@MainActor
final class FeatureModelProductionTests: XCTestCase {
    private func book(
        _ title: String,
        author: String = "Author",
        hash: String = UUID().uuidString,
        lastOpened: Date? = nil,
        order: Int? = nil
    ) -> Book {
        Book(
            title: title,
            author: author,
            format: .epub,
            filePath: "/tmp/\(UUID().uuidString).epub",
            md5Hash: hash,
            lastOpened: lastOpened,
            manualSortOrder: order
        )
    }

    private var headings: [Heading] {
        [
            Heading(level: 1, text: "Part"),
            Heading(level: 2, text: "Chapter One"),
            Heading(level: 3, text: "Section"),
            Heading(level: 4, text: "Detail"),
            Heading(level: 2, text: "Chapter Two"),
        ]
    }

    func testRecentOnlyIncludesOpenedBooks() {
        let result = LibraryBookSorter.recent([
            book("Opened", lastOpened: Date()), book("New", lastOpened: nil),
        ])
        XCTAssertEqual(result.map(\.title), ["Opened"])
    }

    func testRecentSortsNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        let result = LibraryBookSorter.recent([
            book("Old", lastOpened: base),
            book("New", lastOpened: base.addingTimeInterval(10)),
        ])
        XCTAssertEqual(result.map(\.title), ["New", "Old"])
    }

    func testRecentIsLimitedToTenBooks() {
        let books = (0..<15).map { book("\($0)", lastOpened: Date(timeIntervalSince1970: Double($0))) }
        XCTAssertEqual(LibraryBookSorter.recent(books).count, 10)
    }

    func testBookmarkStoresNote() {
        XCTAssertEqual(Bookmark(number: 1, chapterIndex: 0, characterOffset: 2, label: "Note").label, "Note")
    }

    func testBookmarkDefaultsToEmptyNote() {
        XCTAssertEqual(Bookmark(number: 1, chapterIndex: 0, characterOffset: 2).label, "")
    }

    func testBookmarkNoteRoundTripsThroughJSON() throws {
        let original = Bookmark(number: 1, chapterIndex: 2, characterOffset: 9, label: "Remember")
        let decoded = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.label, "Remember")
        XCTAssertEqual(decoded.chapterIndex, 2)
    }

    func testBookmarkAccessibilityIncludesNote() {
        let bookmark = Bookmark(number: 3, chapterIndex: 1, characterOffset: 0, label: "Important")
        XCTAssertEqual(
            bookmark.accessibilityLabel(headingText: "The Battle"),
            "Bookmark 3, The Battle, Note: Important"
        )
    }

    func testBookmarkAccessibilityOmitsEmptyNote() {
        let bookmark = Bookmark(number: 3, chapterIndex: 1, characterOffset: 0)
        XCTAssertEqual(bookmark.accessibilityLabel(headingText: "The Battle"), "Bookmark 3, The Battle")
    }

    /// Without a known heading the location is omitted; the model never
    /// substitutes a content-unit number.
    func testBookmarkAccessibilityOmitsUnknownHeading() {
        let bookmark = Bookmark(number: 3, chapterIndex: 1, characterOffset: 0, label: "Important")
        XCTAssertEqual(bookmark.accessibilityLabel(headingText: nil), "Bookmark 3, Note: Important")
        XCTAssertEqual(bookmark.accessibilityLabel(headingText: "   "), "Bookmark 3, Note: Important")
    }

    func testLastOpenedBookIDRoundTripsAsUUIDString() {
        let id = UUID()
        XCTAssertEqual(UUID(uuidString: id.uuidString), id)
    }

    func testEmptyLastOpenedBookIDIsNotUUID() {
        XCTAssertNil(UUID(uuidString: ""))
    }

    func testLastOpenedBookCanBeFoundByUUID() {
        let target = book("Target")
        XCTAssertEqual([book("Other"), target].first { $0.id == target.id }?.title, "Target")
    }

    func testHeadingFilterLevelSixShowsAll() {
        XCTAssertEqual(HeadingNavigatorView.filteredHeadings(headings, maximumLevel: 6).count, 5)
    }

    func testHeadingFilterLevelTwoShowsH1AndH2() {
        XCTAssertEqual(
            HeadingNavigatorView.filteredHeadings(headings, maximumLevel: 2).map(\.text),
            ["Part", "Chapter One", "Chapter Two"]
        )
    }

    func testHeadingFilterLevelOneShowsOnlyH1() {
        XCTAssertEqual(HeadingNavigatorView.filteredHeadings(headings, maximumLevel: 1).map(\.text), ["Part"])
    }

    func testHeadingLevelsAreUniqueAndSorted() {
        XCTAssertEqual(HeadingNavigatorView.levelsPresent(in: headings), [1, 2, 3, 4])
    }

    func testSingleHeadingLevelCanHideFilter() {
        let sameLevel = [Heading(level: 2, text: "A"), Heading(level: 2, text: "B")]
        XCTAssertEqual(HeadingNavigatorView.levelsPresent(in: sameLevel).count, 1)
    }

    /// The filter offers "H1–Hn" for every level present but the deepest,
    /// whose choice would show every heading as "All" does: the same filter
    /// twice before VoiceOver, and two choices with one tag for a book with
    /// level-6 headings.
    func testHeadingFilterOffersNoChoiceThatDuplicatesAll() {
        XCTAssertEqual(HeadingNavigatorView.filterLevels(for: [1, 2, 3, 4]), [1, 2, 3])
        XCTAssertEqual(HeadingNavigatorView.filterLevels(for: [1, 3]), [1])
        XCTAssertEqual(HeadingNavigatorView.filterLevels(for: [1, 2, 6]), [1, 2])
        XCTAssertEqual(HeadingNavigatorView.filterLevels(for: [2]), [])
        XCTAssertEqual(HeadingNavigatorView.filterLevels(for: []), [])
        XCTAssertEqual(
            HeadingNavigatorView.filterLevels(for: HeadingNavigatorView.levelsPresent(in: headings)),
            [1, 2, 3]
        )
    }

    func testCurrentHeadingDetectionCanUseFilteredHeadings() {
        let positioned = [
            Heading(level: 1, text: "Visible", chapterIndex: 0, characterOffset: 0),
            Heading(level: 3, text: "Hidden", chapterIndex: 0, characterOffset: 50),
        ]
        let filtered = HeadingNavigatorView.filteredHeadings(positioned, maximumLevel: 1)
        XCTAssertEqual(ReaderViewModel.currentHeading(in: filtered, chapterIndex: 0, characterOffset: 100)?.text, "Visible")
    }

    func testHeadingDurationsEndAtNextDisplayedHeading() {
        let positioned = [
            Heading(level: 1, text: "Part One", characterOffset: 0),
            Heading(level: 2, text: "Chapter One", characterOffset: 100),
            Heading(level: 3, text: "Scene", characterOffset: 250),
            Heading(level: 1, text: "Part Two", characterOffset: 400),
            Heading(level: 2, text: "Chapter Two", characterOffset: 500),
        ]
        let displayed = HeadingNavigatorView.filteredHeadings(positioned, maximumLevel: 1)
        let offsets = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0.characterOffset) })

        let nextOffsets = HeadingNavigatorView.nextDisplayedHeadingOffsets(
            displayed,
            globalOffsetsByID: offsets,
            totalCharacterCount: 700
        )

        // The hidden H2/H3 headings must remain inside Part One's 400-character
        // duration rather than cutting it off at the first hidden H2.
        XCTAssertEqual(nextOffsets[displayed[0].id], 400)
        XCTAssertEqual(nextOffsets[displayed[1].id], 700)
    }

    func testHeadingDurationsRespectLessRestrictiveDisplayFilter() {
        let positioned = [
            Heading(level: 1, text: "Part One", characterOffset: 0),
            Heading(level: 2, text: "Chapter One", characterOffset: 100),
            Heading(level: 3, text: "Hidden Scene", characterOffset: 250),
            Heading(level: 1, text: "Part Two", characterOffset: 400),
        ]
        let displayed = HeadingNavigatorView.filteredHeadings(positioned, maximumLevel: 2)
        let offsets = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0.characterOffset) })

        let nextOffsets = HeadingNavigatorView.nextDisplayedHeadingOffsets(
            displayed,
            globalOffsetsByID: offsets,
            totalCharacterCount: 700
        )

        XCTAssertEqual(nextOffsets[displayed[0].id], 100)
        XCTAssertEqual(nextOffsets[displayed[1].id], 400)
        XCTAssertEqual(nextOffsets[displayed[2].id], 700)
    }

    func testPlainSearchFindsAcrossRepresentativeChapterTexts() throws {
        XCTAssertEqual(try BookTextSearch.ranges(in: "one target two", query: "target", useRegex: false).count, 1)
        XCTAssertEqual(try BookTextSearch.ranges(in: "target again target", query: "target", useRegex: false).count, 2)
    }

    func testPlainSearchIsCaseInsensitive() throws {
        XCTAssertEqual(try BookTextSearch.ranges(in: "Alpha ALPHA alpha", query: "alpha", useRegex: false).count, 3)
    }

    func testRegexSearchMatchesPattern() throws {
        XCTAssertEqual(try BookTextSearch.ranges(in: "cat cot cut", query: "c[ao]t", useRegex: true).count, 2)
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try BookTextSearch.ranges(in: "text", query: "[", useRegex: true))
    }

    func testSearchWithNoMatchesReturnsEmpty() throws {
        XCTAssertTrue(try BookTextSearch.ranges(in: "text", query: "absent", useRegex: false).isEmpty)
    }

    func testEmptySearchQueryReturnsEmpty() throws {
        XCTAssertTrue(try BookTextSearch.ranges(in: "text", query: "", useRegex: false).isEmpty)
    }

    func testSearchOffsetCalculatesPercentageWithDocumentModel() throws {
        let range = try XCTUnwrap(BookTextSearch.ranges(in: "0123456789", query: "5", useRegex: false).first)
        let content = DocumentContent(
            title: "Test",
            author: "Author",
            chapters: [Chapter(text: "0123456789")]
        )
        XCTAssertEqual(content.percentComplete(globalOffset: range.location), 50)
    }

    func testRegexSearchSupportsGroups() throws {
        let ranges = try BookTextSearch.ranges(in: "Date 2024-01-15", query: #"(\d{4})-(\d{2})-(\d{2})"#, useRegex: true)
        XCTAssertEqual(ranges.first?.length, 10)
    }

    /// The copied position uses Where Am I's heading vocabulary: the heading
    /// text, then its number among all of the book's headings.
    func testCopyPositionBuildsFormattedSummary() {
        let headings = (0..<9).map { Heading(level: 1, text: "Part \($0 + 1)", chapterIndex: $0, characterOffset: 0) }
        let summary = ReaderViewModel.readingPositionSummary(
            bookTitle: "The Great Gatsby",
            author: "F. Scott Fitzgerald",
            locationTitle: "Part 3",
            headingPosition: HeadingPosition(in: headings, chapterIndex: 2, characterOffset: 5),
            percentComplete: 33.3,
            formattedTimeRemaining: "2:15:00"
        )
        XCTAssertEqual(
            summary,
            "The Great Gatsby | by F. Scott Fitzgerald | Part 3 | Heading 3 of 9 | 33.3% through | 2:15:00 remaining"
        )
    }

    func testCopyPositionOmitsUnknownAuthor() {
        XCTAssertEqual(ReaderViewModel.readingPositionSummary(parts: ["My Book", "by Unknown"]), "My Book")
    }

    /// Missing authors, headings, and heading numbers leave no empty fields.
    func testCopyPositionOmitsEmptyFields() {
        let summary = ReaderViewModel.readingPositionSummary(
            bookTitle: "My Book",
            author: "",
            locationTitle: nil,
            headingPosition: HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0),
            percentComplete: 0,
            formattedTimeRemaining: "0:30"
        )
        XCTAssertEqual(summary, "My Book | 0.0% through | 0:30 remaining")
    }

    func testCopyReadingPositionNotificationExists() {
        XCTAssertEqual(Notification.Name.copyReadingPosition.rawValue, "copyReadingPosition")
    }

    func testSearchInBookNotificationExists() {
        XCTAssertEqual(Notification.Name.searchInBook.rawValue, "searchInBook")
    }

    func testNewFromTextNotificationExists() {
        XCTAssertEqual(Notification.Name.newFromText.rawValue, "newFromText")
    }

    func testReadingStatsRoundTrip() throws {
        let stats = ReadingStats(
            dailyListeningSeconds: ["2026-03-20": 3_600],
            totalListeningSeconds: 3_600,
            bookListeningSeconds: ["id": 1_800],
            finishedBooks: [FinishedBookEntry(bookID: "id", title: "Book", dateFinished: Date(timeIntervalSince1970: 1))]
        )
        let decoded = try JSONDecoder().decode(ReadingStats.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(decoded.totalListeningSeconds, 3_600)
        XCTAssertEqual(decoded.finishedBooks.first?.title, "Book")
    }

    func testEmptyReadingStatsRoundTrip() throws {
        let decoded = try JSONDecoder().decode(ReadingStats.self, from: JSONEncoder().encode(ReadingStats()))
        XCTAssertTrue(decoded.dailyListeningSeconds.isEmpty)
        XCTAssertEqual(decoded.totalListeningSeconds, 0)
    }

    func testReadingStatsDateKeyUsesYearMonthDay() {
        // Built in the Gregorian calendar that day keys always use, so the
        // test holds on a Mac set to any other calendar.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let date = gregorian.date(
            from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)
        )!
        XCTAssertEqual(ReadingStatsService.dateKey(date), "2026-03-20")
    }

    func testReadingStatsStreakCountsConsecutiveDays() {
        let now = Date()
        let calendar = Calendar.current
        let values = Dictionary(uniqueKeysWithValues: (0..<3).map { offset in
            (ReadingStatsService.dateKey(calendar.date(byAdding: .day, value: -offset, to: now)!), 120.0)
        })
        XCTAssertEqual(ReadingStatsService.streak(in: values, through: now), 3)
    }

    func testSessionDurationUsesDateInterval() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(start.addingTimeInterval(1_800).timeIntervalSince(start), 1_800)
    }

    func testPunctuationLevelZeroLeavesTextUnchanged() {
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("Hello. World", level: 0).text, "Hello. World")
    }

    func testPunctuationLevelOneAddsPeriodPause() {
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("Hello. World", level: 1).text, "Hello.. World")
    }

    func testPunctuationLevelOneAddsQuestionAndExclamationPauses() {
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("Yes! Why? Now", level: 1).text, "Yes!. Why?. Now")
    }

    func testPunctuationLevelTwoAddsCommaPause() {
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("One, two", level: 2).text, "One,, two")
    }

    func testPunctuationLevelThreeAddsParagraphPause() {
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("One\n\nTwo", level: 3).text, "One\n\n.\n\nTwo")
    }

    func testEndOfBookBehaviorHasThreeCases() {
        XCTAssertEqual(EndOfBookBehavior.allCases.count, 3)
    }

    func testEndOfBookBehaviorRawValuesRoundTrip() {
        for behavior in EndOfBookBehavior.allCases {
            XCTAssertEqual(EndOfBookBehavior(rawValue: behavior.rawValue), behavior)
        }
    }

    func testEndOfBookBehaviorUsesPerBookOverride() {
        XCTAssertEqual(EndOfBookBehavior.effective(localRawValue: "Continue to Next Book", global: .stop), .continueNext)
    }

    func testEndOfBookBehaviorFallsBackToGlobal() {
        XCTAssertEqual(EndOfBookBehavior.effective(localRawValue: nil, global: .loop), .loop)
    }

    func testManualSortUsesOrderThenTitle() {
        let sorted = LibraryBookSorter.sorted([
            book("C", order: 2), book("A", order: nil), book("B", order: 0), book("D", order: 1),
        ], by: .manual, ascending: true)
        XCTAssertEqual(sorted.map(\.title), ["B", "D", "C", "A"])
    }

    func testNextBookInManualOrderCanBeFound() {
        let sorted = LibraryBookSorter.sorted([book("First", order: 0), book("Second", order: 1), book("Third", order: 2)], by: .manual, ascending: true)
        XCTAssertEqual(sorted[sorted.firstIndex { $0.title == "Second" }! + 1].title, "Third")
    }

    func testLastBookInManualOrderHasNoSuccessor() {
        let sorted = LibraryBookSorter.sorted([book("First", order: 0), book("Last", order: 1)], by: .manual, ascending: true)
        XCTAssertEqual(sorted.firstIndex { $0.title == "Last" }! + 1, sorted.count)
    }

    func testBookStatePersistsManualOrderAndEndBehavior() throws {
        let state = BookState(isNew: false, tmbDirectoryName: "test.tmb", localEndOfBookBehavior: "Loop to Start", manualSortOrder: 5)
        let decoded = try JSONDecoder().decode(BookState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.manualSortOrder, 5)
        XCTAssertEqual(decoded.localEndOfBookBehavior, "Loop to Start")
    }

    func testBookStateDecodesWithoutNewOrderingFields() throws {
        let data = #"{"isNew":true,"tmbDirectoryName":"old.tmb"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BookState.self, from: data)
        XCTAssertNil(decoded.manualSortOrder)
        XCTAssertNil(decoded.localEndOfBookBehavior)
    }

    func testAudioBookFormatContainsSupportedExtensions() {
        XCTAssertTrue(BookFormat.audio.isAudio)
        XCTAssertTrue(["mp3", "m4b", "wav", "flac"].allSatisfy(BookFormat.audio.fileExtensions.contains))
    }

    func testAudioBookFormatDetectsExtensions() {
        for ext in BookFormat.audio.fileExtensions {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "book.\(ext)")), .audio)
        }
    }

    func testAudioPlaceholderUsesTenCharactersPerSecond() {
        XCTAssertEqual(AudioBookParser.placeholderLength(for: 300), 3_000)
    }

    func testAudioTimeUsesCharactersInsteadOfWords() {
        let placeholder = String(repeating: " ", count: AudioBookParser.placeholderLength(for: 3_600))
        XCTAssertEqual(placeholder.split(whereSeparator: \.isWhitespace).count, 0)
        XCTAssertEqual(AudioBookParser.time(forCharacterOffset: placeholder.utf16Length), 3_600)
    }

    func testAudioSkipConvertsSecondsToCharacterOffsets() {
        XCTAssertEqual(AudioBookParser.characterOffset(forTime: 30), 300)
        XCTAssertEqual(AudioBookParser.characterOffset(forTime: 15), 150)
    }

    func testAudioSpeedRangeIsQuarterToFourX() {
        let playback = AudioPlaybackService()
        XCTAssertEqual(playback.minimumSpeed, 0.25)
        XCTAssertEqual(playback.maximumSpeed, 4)
    }

    func testAudioSpeedClampsThroughPlaybackService() {
        let playback = AudioPlaybackService()
        playback.setSpeed(0.1)
        XCTAssertEqual(playback.playbackSpeed, 0.25)
        playback.setSpeed(5)
        XCTAssertEqual(playback.playbackSpeed, 4)
    }

    func testAudioTimeEstimateAdjustsForPlaybackSpeed() {
        XCTAssertEqual(AudioBookParser.time(forCharacterOffset: 36_000) / 2, 1_800)
    }

    func testAudioRemainingTimeUsesRemainingCharacterFraction() {
        let remaining = AudioBookParser.time(forCharacterOffset: 36_000 - 18_000) / 1.5
        XCTAssertEqual(remaining, 1_200)
    }

    func testAudioManifestRoundTripsThroughJSON() throws {
        let manifest = AudioManifest(title: "Book", author: "Writer", chapters: ["01.mp3": "Intro"], order: ["01.mp3"], segments: nil)
        let decoded = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.title, "Book")
        XCTAssertEqual(decoded.chapters?["01.mp3"], "Intro")
    }

    func testAudioFilesSortAlphabeticallyByDefault() {
        XCTAssertEqual(AudioBookParser.orderedFileNames(["03.mp3", "01.mp3", "02.mp3"]), ["01.mp3", "02.mp3", "03.mp3"])
    }

    func testAudioManifestOrderOverridesAlphabeticalOrder() {
        XCTAssertEqual(AudioBookParser.orderedFileNames(["c.mp3", "a.mp3", "b.mp3"], manifestOrder: ["b.mp3", "a.mp3", "c.mp3"]), ["b.mp3", "a.mp3", "c.mp3"])
    }

    func testAudioChapterPlaceholderUsesEachFileDuration() {
        XCTAssertEqual([60.0, 300, 450].map(AudioBookParser.placeholderLength), [600, 3_000, 4_500])
    }

    func testAudioPositionConvertsCharactersToTimeAndBack() {
        XCTAssertEqual(AudioBookParser.time(forCharacterOffset: 5_000), 500)
        XCTAssertEqual(AudioBookParser.characterOffset(forTime: 123.4), 1_234)
    }

    func testDuplicateMD5FindsExactMatches() {
        XCTAssertEqual(duplicates([book("A", hash: "same"), book("B", hash: "same")], filter: .md5Hash).count, 1)
    }

    func testDuplicateMD5SkipsEmptyHashes() {
        XCTAssertTrue(duplicates([book("A", hash: ""), book("B", hash: "")], filter: .md5Hash).isEmpty)
    }

    func testDuplicateTitleIsCaseInsensitive() {
        XCTAssertEqual(duplicates([book("Shared"), book("shared")], filter: .title).count, 1)
    }

    func testDuplicateAuthorSkipsUnknownAuthor() {
        XCTAssertTrue(duplicates([book("A", author: "Unknown"), book("B", author: "Unknown")], filter: .author).isEmpty)
    }

    func testDuplicateTitleAndAuthorUsesCombinedKey() {
        let groups = DuplicateFinderEngine.findDuplicates(
            books: [book("Shared", author: "Same"), book("shared", author: "same")],
            filters: [.titleAndAuthor], isbnCache: [:]
        )
        XCTAssertEqual(groups.count, 1)
    }

    func testDuplicateDetectionReturnsEmptyForUniqueBooks() {
        XCTAssertTrue(duplicates([book("A"), book("B")], filter: .title).isEmpty)
    }

    func testDuplicateDetectionFindsMultipleGroups() {
        let groups = duplicates([book("A"), book("a"), book("B"), book("b")], filter: .title)
        XCTAssertEqual(groups.count, 2)
    }

    func testDuplicateISBNFindsSameIdentifier() {
        let first = book("A")
        let second = book("B")
        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second], filters: [.isbn], isbnCache: [first.id: "978-1", second.id: "978-1"]
        )
        XCTAssertEqual(groups.count, 1)
    }

    func testDuplicateISBNSkipsEmptyIdentifiers() {
        let first = book("A")
        let second = book("B")
        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second], filters: [.isbn], isbnCache: [first.id: "", second.id: ""]
        )
        XCTAssertTrue(groups.isEmpty)
    }

    private func duplicates(_ books: [Book], filter: DuplicateFilter) -> [DuplicateGroup] {
        DuplicateFinderEngine.findDuplicates(books: books, filters: [filter], isbnCache: [:])
    }
}
