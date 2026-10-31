import XCTest
@testable import TextMouth

/// "Text as spoken audio" as a kind of the Export job runner (FMT43): a text
/// book offers it from its text cache, for one book at a time; it is never
/// copied, so nothing is planned for it as it is; and the kind's words.
///
/// Every book lives in a library folder of the test's own, and every export
/// goes to a sandbox folder; nothing reaches the user's Documents or library.
@MainActor
final class SpeechExportServiceTests: XCTestCase {

    // MARK: - The Offer

    /// A text book offers its text as spoken audio last of its own kinds,
    /// right after the plain text: one file named after the book, as M4B,
    /// read from its text cache, its size unknown before it is spoken.
    func testATextBookOffersItsTextAsSpokenAudio() throws {
        let world = try makeIntegrationWorld("Speech Export Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let cache = MarkdownCacheService.cacheURL(for: book)

        let offer = BookExportService.offer(for: book)

        XCTAssertEqual(offer.items.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        let spoken = try XCTUnwrap(offer.item(.spokenAudio))
        XCTAssertEqual(spoken.suggestedName, "\(stem) - Audio.m4b")
        XCTAssertNil(spoken.folderName, "the file stands alone")
        XCTAssertEqual(
            spoken.files,
            [BookExportFile(source: .spoken(fromMarkdown: cache), path: "\(stem) - Audio.m4b", byteCount: 0)]
        )
        XCTAssertEqual(spoken.byteCount, 0, "its size is not known before it is spoken")
        XCTAssertFalse(spoken.isInCloud)
    }

    /// Only a text book with its text cache offers spoken audio: an
    /// audiobook does not, even with a transcript's text as its content.md,
    /// and neither does a text book whose content.md is gone.
    func testOnlyATextBookWithItsTextCacheOffersSpokenAudio() throws {
        let world = try makeIntegrationWorld("Speech Export Offer Kinds")
        let audiobook = try world.makeSilentAudioBook(title: "Night Shift Notes", trackDurations: [1])
        try Data("<!-- chapter: Start -->\nThe tide turns at nine.".utf8)
            .write(to: MarkdownCacheService.cacheURL(for: audiobook))
        let textBook = try world.importBook(from: writeSource(named: "Lock Keeper.md"))
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: textBook))

        XCTAssertNil(BookExportService.offer(for: audiobook).item(.spokenAudio), "an audiobook offered spoken audio")
        XCTAssertNil(BookExportService.offer(for: textBook).item(.spokenAudio), "a book without its text cache offered it")
    }

    /// A text cache only in the cloud makes spoken audio in the cloud: its
    /// checkbox is unavailable and says so.
    func testATextCacheInTheCloudMakesSpokenAudioInTheCloud() throws {
        let world = try makeIntegrationWorld("Speech Export Cloud Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = FakeCloudFiles()
        cloud.markDataless(cache)
        cloud.refuseReads(of: cache)

        let offer = BookExportService.offer(for: book, access: cloud.access)

        XCTAssertEqual(offer.item(.spokenAudio)?.fileInCloud, cache)
        let choice = try XCTUnwrap(BookExportChoice.choices(for: [offer]).first { $0.kind == .spokenAudio })
        XCTAssertFalse(choice.isAvailable)
        XCTAssertEqual(choice.label, "Text as spoken audio, in the cloud")
    }

    // MARK: - The Choice

    /// The dialog lists spoken audio when it exports one book, as its
    /// range and sliders are that book's, and never for several.
    func testSpokenAudioIsAChoiceForOneBookAlone() throws {
        let world = try makeIntegrationWorld("Speech Export Choice")
        let first = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let second = try world.importBook(from: writeSource(named: "Lock Keeper.md"))

        let alone = BookExportChoice.choices(for: [BookExportService.offer(for: first)])
        let together = BookExportChoice.choices(for: [first, second].map { BookExportService.offer(for: $0) })

        XCTAssertEqual(alone.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        XCTAssertEqual(alone.last?.label, "Text as spoken audio")
        XCTAssertEqual(alone.last?.isAvailable, true)
        XCTAssertEqual(together.map(\.kind), [.originalFile, .markdown, .plainText], "several books were offered spoken audio")
    }

    // MARK: - The Plan

    /// Spoken audio is never copied: as it is, or with a text conversion,
    /// nothing is planned for it, and that is no failure; the other kinds'
    /// plans are as they were.
    func testNothingIsPlannedForSpokenAudioAsItIs() throws {
        let world = try makeIntegrationWorld("Speech Export Plan Nothing")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Speech Export Plan Nothing Folder")
        let offer = BookExportService.offer(for: book)
        /// The files planned for `kinds` with `conversions`.
        func plan(
            _ kinds: Set<BookExportKind>,
            _ conversions: [BookExportKind: BookExportConversion] = [:]
        ) -> [BookExportService.PlannedFile] {
            BookExportService.plan([offer], kinds: kinds, conversions: conversions, in: folder).files
        }

        XCTAssertEqual(plan([.spokenAudio]), [], "spoken audio was planned as it is")
        XCTAssertEqual(plan([.spokenAudio], [.spokenAudio: .markdown]), [], "a text conversion made spoken audio")
        let others: Set<BookExportKind> = [.originalFile, .markdown, .plainText]
        XCTAssertEqual(plan(others.union([.spokenAudio])), plan(others), "the other kinds' plans changed")
    }

    /// The spoken placeholder is never written as it is: met by a text
    /// conversion's mapping it is left out, and should one ever be planned as
    /// it is, it fails alone, named with the reason, leaving nothing.
    func testASpokenPlaceholderIsLeftOutOrFailsAloneButNeverWritten() throws {
        let world = try makeIntegrationWorld("Speech Export Placeholder")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let folder = try makeSandboxDirectory("Speech Export Placeholder Folder")
        let placeholder = BookExportFile(source: .spoken(fromMarkdown: cache), path: "Stray.m4b", byteCount: 0)
        let offer = BookExportOffer(
            book: book,
            items: [
                BookExportItem(kind: .markdown, folderName: nil, files: [placeholder], fileInCloud: nil),
                BookExportItem(kind: .plainText, folderName: nil, files: [placeholder], fileInCloud: nil),
            ],
            isPackageInCloud: false
        )

        let converted = BookExportService.plan([offer], kinds: [.markdown], conversions: [.markdown: .markdown], in: folder)
        let outcome = BookExportService.export([offer], kinds: [.plainText], to: folder)

        XCTAssertEqual(converted.files, [], "a text conversion planned the placeholder")
        XCTAssertEqual(outcome.exported, [])
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(
            outcome.failures,
            [BookExportFailure(name: "Stray.m4b", reason: CocoaError(.featureUnsupported).localizedDescription)]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - The Words

    /// The kind's name, hint, and checkbox label, which says no size, even
    /// given one, and no file count; a conversion's name never changes them.
    func testTheKindsWords() {
        XCTAssertEqual(BookExportKind.spokenAudio.order, BookExportKind.plainText.order + 1, "listed right after the plain text")
        XCTAssertFalse(BookExportKind.spokenAudio.convertsText)
        XCTAssertEqual(BookExportWording.name(of: .spokenAudio), "Text as spoken audio")
        XCTAssertEqual(
            BookExportWording.hint(for: .spokenAudio),
            "The book's text spoken by its voice into one audio file, with a chapter for each heading."
        )
        XCTAssertEqual(BookExportWording.name(of: .spokenAudio, convertedTo: "HTML"), "Text as spoken audio")
        XCTAssertEqual(BookExportWording.hint(for: .spokenAudio, convertedTo: "HTML"), BookExportWording.hint(for: .spokenAudio))
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 0, inCloudCount: 0),
            "Text as spoken audio"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 2, byteCount: 1_200_000, inCloudCount: 0
            ),
            "Text as spoken audio",
            "a size or a file count was said"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 0, inCloudCount: 0,
                convertedTo: "HTML"
            ),
            "Text as spoken audio"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .spokenAudio, bookCount: 1, availableItemCount: 0, fileCount: 0, byteCount: 0, inCloudCount: 1),
            "Text as spoken audio, in the cloud"
        )
    }

    // MARK: - Fixtures

    /// Two chapters with three headings, the last of level 2, as a Markdown
    /// book with chapter markers holds them.
    private static let twoChapters = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.

    ## Later

    Six seven eight.
    """

    /// Writes the two-chapter book as a file named `name` in a sandbox
    /// folder of its own, for an import to read.
    private func writeSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("Speech Export Source").appendingPathComponent(name)
        try Data(Self.twoChapters.utf8).write(to: file)
        return file
    }
}
