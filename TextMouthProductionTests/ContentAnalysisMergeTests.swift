import XCTest
@testable import TextMouth

/// A content analysis can run for minutes on a copy of its book taken when it
/// started. Its result must change only the fields an analysis owns, and
/// must land on the latest state of the book, never on that old copy
/// (TODO S05).
final class ContentAnalysisMergeTests: XCTestCase {

    // MARK: - The Fields an Analysis Owns

    /// Setting a book's analysis fields changes exactly the five fields an
    /// analysis owns. Every other field (reading state, bookmarks, settings,
    /// metadata, and where the package is) keeps its value, so neither a
    /// package record nor a library row can lose user state to an analysis.
    func testSettingAnalysisFieldsChangesNothingElse() {
        let user = Self.bookWithEveryFieldSet(seed: 1)
        let analysis = Self.bookWithEveryFieldSet(seed: 2)
        XCTAssertEqual(
            Self.fieldsThatDiffer(user, analysis).count,
            Mirror(reflecting: user).children.count,
            "the fixtures must differ in every field, or this test proves nothing about it"
        )

        var changed = user
        changed.contentAnalysisFields = analysis.contentAnalysisFields

        XCTAssertEqual(changed.contentAnalysisFields, analysis.contentAnalysisFields)
        XCTAssertEqual(
            Set(Self.fieldsThatDiffer(user, changed)),
            ["totalWordCount", "totalCharacterCount", "audioDuration", "contentIndexVersion", "cacheFormatVersion"]
        )
    }

    /// Applying an analysis records the statistics and version of its index
    /// and the cache version the analysis vouches for. One that vouches for
    /// no cache keeps the book's cache version, as a bare summary does.
    func testApplyingAnAnalysisRecordsItsIndexAndTheCacheItVouchesFor() {
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )

        var vouched = Self.bookWithEveryFieldSet(seed: 3)
        vouched.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(vouched.contentAnalysisFields, Book.ContentAnalysisFields(
            totalWordCount: 3,
            totalCharacterCount: index.totalCharacterCount,
            audioDuration: index.totalAudioDuration,
            contentIndexVersion: index.version,
            cacheFormatVersion: "9.9.9"
        ))

        var silent = Self.bookWithEveryFieldSet(seed: 3)
        silent.applyContentAnalysis(index, cacheFormatVersion: nil)
        XCTAssertEqual(silent.cacheFormatVersion, "cache-3")
        XCTAssertEqual(silent.totalWordCount, 3)

        var summarized = Self.bookWithEveryFieldSet(seed: 3)
        summarized.applyContentIndexSummary(index)
        XCTAssertEqual(summarized.contentAnalysisFields, silent.contentAnalysisFields)
    }

    // MARK: - Fixtures

    /// A book with every field set, each to a value derived from `seed`, so
    /// books made from two different seeds differ in every field.
    private static func bookWithEveryFieldSet(seed: Int) -> Book {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seed * 1_000))
        return Book(
            id: UUID(),
            title: "Title \(seed)",
            author: "Author \(seed)",
            format: seed.isMultiple(of: 2) ? .epub : .txt,
            filePath: "/library/book-\(seed).txt",
            md5Hash: "hash-\(seed)",
            folderPath: "Folder \(seed)",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(1),
            readingPosition: ReadingPosition(chapterIndex: seed, characterOffset: seed * 10),
            bookmarks: [
                Bookmark(number: seed, chapterIndex: seed, characterOffset: seed, label: "Mark \(seed)", dateCreated: date)
            ],
            totalWordCount: seed * 100,
            totalCharacterCount: seed * 500,
            tmbDirectoryName: "Package-\(seed).tmb",
            sourceFilePath: "/sources/book-\(seed).txt",
            lastPlaybackStarted: date.addingTimeInterval(2),
            lastPlaybackStopped: date.addingTimeInterval(3),
            localVoiceID: "voice.\(seed)",
            localWPM: Double(200 + seed),
            localPitch: 1 + Double(seed) / 10,
            skippedHeadingIDs: ["heading-\(seed)"],
            localEndOfBookBehavior: "behavior-\(seed)",
            localSkipForwardUnit: "forward-\(seed)",
            localSkipBackwardUnit: "backward-\(seed)",
            manualSortOrder: seed,
            audioDuration: TimeInterval(seed * 60),
            audioAlbum: "Album \(seed)",
            audioGenre: "Genre \(seed)",
            audioYear: "\(2000 + seed)",
            epubPublisher: "Publisher \(seed)",
            epubPublicationDate: "Published \(seed)",
            epubISBN: "ISBN \(seed)",
            epubLanguage: "language-\(seed)",
            epubIdentifier: "identifier-\(seed)",
            epubVersion: "version-\(seed)",
            cacheFormatVersion: "cache-\(seed)",
            contentIndexVersion: "index-\(seed)"
        )
    }

    /// The names of `Book`'s stored properties whose values differ between
    /// `a` and `b`.
    private static func fieldsThatDiffer(_ a: Book, _ b: Book) -> [String] {
        zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).compactMap { left, right in
            String(reflecting: left.value) == String(reflecting: right.value) ? nil : left.label
        }
    }
}
