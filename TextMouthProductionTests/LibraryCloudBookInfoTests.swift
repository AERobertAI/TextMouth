import Foundation
import XCTest
@testable import TextMouth

/// The library's Book Info reads a book's metadata off the main thread, and
/// never downloads a book whose file is only in the cloud: for that book it
/// shows the metadata the library keeps, with a note that some details
/// appear once the book is downloaded (FR02).
///
/// Whether a book is only in the cloud is decided from its package and then
/// its file, each looked at with downloading switched off; the readers'
/// dataless check is asked only of an item that look found. So the books
/// these tests hand a scripted check have real files, in packages of their
/// own, which the scripted reads never parse.
@MainActor
final class LibraryCloudBookInfoTests: XCTestCase {
    // MARK: - EPUB

    /// An EPUB on this Mac is read off the main thread, and the library's
    /// own edits are laid over what the file says. Its package is looked at
    /// first, then its file, and only then is it read.
    func testEPUBMetadataIsReadOffTheMainThread() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        let book = try inAPackage(epubBook())

        let info = await reader.info(for: book)

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch", "the library's title wins")
        XCTAssertEqual(metadata.publisher, "Blackwood", "the library's publisher wins")
        XCTAssertEqual(metadata.isbn, "9780141439549", "the file's ISBN shows")
        XCTAssertEqual(calls.names, ["isDataless package", "isDataless file", "readEPUB"])
        XCTAssertEqual(calls.onMainThread, [false, false, false])
    }

    /// An EPUB only in the cloud, evicted on its own as a sync service that
    /// syncs each file evicts it, is not read at all: Book Info shows the
    /// metadata the library keeps, and says the rest comes with the download.
    func testCloudOnlyEPUBShowsTheLibrarysMetadataWithoutReading() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return itemKind(url) == "file" },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        let book = try inAPackage(epubBook())

        let info = await reader.info(for: book)

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch")
        XCTAssertEqual(metadata.author, "George Eliot")
        XCTAssertEqual(metadata.publisher, "Blackwood")
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.isbn, "", "the library keeps no ISBN for this book")
        XCTAssertEqual(calls.names, ["isDataless package", "isDataless file"], "the file is never read")
        XCTAssertEqual(LibraryBookInfo.cloudOnlyNote, "Some details appear once the book is downloaded.")
    }

    /// An EPUB whose package iCloud Drive evicted whole, leaving the
    /// package's folder dataless, is only in the cloud too (board #624):
    /// nothing inside the package is looked at or read, since a look at the
    /// file there with downloading allowed would bring the whole book back
    /// down. Book Info shows the metadata the library keeps.
    func testEPUBWhosePackageWasEvictedWholeIsNotRead() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return itemKind(url) == "package" },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        let book = try inAPackage(epubBook())

        let info = await reader.info(for: book)

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch")
        XCTAssertEqual(metadata.publisher, "Blackwood")
        XCTAssertEqual(metadata.isbn, "", "the file's ISBN shows, so the file was read")
        XCTAssertEqual(calls.names, ["isDataless package"], "something inside the evicted package was looked at")
    }

    /// An EPUB evicted between the check and the read is refused rather
    /// than downloaded, and shows like one only in the cloud.
    func testEPUBEvictedDuringTheReadShowsTheLibrarysMetadata() async {
        let reader = LibraryBookInfoReader(
            isDataless: { _ in false },
            readEPUBMetadata: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK)) },
            readAudioMetadata: { _ in AudioMetadata() }
        )

        let info = await reader.info(for: epubBook())

        guard case .epub(_, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
    }

    /// An EPUB on this Mac that cannot be read gets the simple sheet, as it
    /// always has.
    func testUnreadableEPUBGetsTheSimpleSheet() async {
        let reader = LibraryBookInfoReader(
            isDataless: { _ in false },
            readEPUBMetadata: { _ in throw CocoaError(.fileReadCorruptFile) },
            readAudioMetadata: { _ in AudioMetadata() }
        )

        guard case .simple = await reader.info(for: epubBook()) else {
            return XCTFail("expected the simple sheet")
        }
    }

    /// The app's reader opens a real EPUB on this Mac, with dataless files
    /// left in the cloud, and finds its metadata.
    func testSystemReaderReadsALocalEPUB() async throws {
        let file = try requireFile("alice.epub")
        var book = epubBook()
        book.filePath = file.path

        let info = await LibraryBookInfoReader.system.info(for: book)

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch", "the library's title is laid over the file's")
        XCTAssertFalse(metadata.epubVersion.isEmpty, "the file's version is read")
    }

    // MARK: - Audio

    /// An audiobook on this Mac has its tags read off the main thread, with
    /// the library's edits laid over them.
    func testAudioMetadataIsReadOffTheMainThread() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in
                calls.note("readAudio")
                return AudioMetadata(title: "Tag Title", artist: "Tag Artist", album: "Tag Album", duration: "9:41", fileFormat: "M4B")
            }
        )
        let book = try inAPackage(audioBook())

        let info = await reader.info(for: book)

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(metadata.title, "Bleak House")
        XCTAssertEqual(metadata.artist, "Charles Dickens")
        XCTAssertEqual(metadata.album, "Serial Edition", "the library's album wins")
        XCTAssertEqual(metadata.duration, "9:41", "the file's length shows")
        XCTAssertEqual(calls.names, ["isDataless package", "isDataless file", "readAudio"])
        XCTAssertEqual(calls.onMainThread, [false, false, false])
    }

    /// A tag read that never returns does not hold the sheet for good: after
    /// the time limit Book Info shows the metadata the library keeps, as
    /// for a book in the cloud but without the note of a download. A later
    /// look at the same file does not start a second read, which would pile
    /// a stuck read on the first.
    func testAudioTagReadThatNeverReturnsGivesTheStoredMetadata() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in false },
            readEPUBMetadata: { _ in epubFileMetadata },
            readAudioMetadata: { _ in
                calls.note("readAudio")
                // Stuck until it is cancelled, which the limit does.
                try? await Task.sleep(for: .seconds(20))
                return AudioMetadata(title: "Late Title", album: "Late Album")
            },
            audioTagsTimeLimit: .milliseconds(300),
            abandonedReads: AsyncBridge.AbandonedReads()
        )
        let book = try inAPackage(audioBook())

        let started = ContinuousClock.now
        let info = await reader.info(for: book)
        let elapsed = ContinuousClock.now - started

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly, "the file is here, so the sheet does not promise a download")
        XCTAssertEqual(metadata.title, "Bleak House", "the library's metadata, not the late tags")
        XCTAssertEqual(metadata.album, "Serial Edition")
        XCTAssertEqual(metadata.fileFormat, "M4B")
        XCTAssertEqual(metadata.duration, "1:02:03")
        XCTAssertLessThan(elapsed, .seconds(10), "the sheet waited on the stuck read")

        let again = await reader.info(for: book)
        guard case .audio(let secondMetadata, _) = again else {
            return XCTFail("expected the audio editor, got \(again)")
        }
        XCTAssertEqual(secondMetadata.title, "Bleak House")
        XCTAssertEqual(secondMetadata.album, "Serial Edition")
        XCTAssertEqual(calls.names, ["readAudio"], "a file whose read was abandoned was read again")
    }

    /// An audiobook only in the cloud is not read: Book Info shows the
    /// library's names, its measured length, and its file's type.
    func testCloudOnlyAudiobookShowsTheLibrarysMetadataWithoutReading() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return itemKind(url) == "file" },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        let book = try inAPackage(audioBook())

        let info = await reader.info(for: book)

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Bleak House")
        XCTAssertEqual(metadata.album, "Serial Edition")
        XCTAssertEqual(metadata.duration, "1:02:03")
        XCTAssertEqual(metadata.fileFormat, "M4B")
        XCTAssertEqual(calls.names, ["isDataless package", "isDataless file"], "the file is never read")
    }

    /// An audiobook whose package iCloud Drive evicted whole is only in the
    /// cloud (board #624): nothing inside the package is looked at, and its
    /// tags are never read.
    func testAudiobookWhosePackageWasEvictedWholeIsNotRead() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return itemKind(url) == "package" },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        let book = try inAPackage(audioBook())

        let info = await reader.info(for: book)

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Bleak House")
        XCTAssertEqual(metadata.duration, "1:02:03")
        XCTAssertEqual(calls.names, ["isDataless package"], "something inside the evicted package was looked at")
    }

    // MARK: - Looking Without Downloading

    /// Every look at a book's files is made with downloading switched off,
    /// for an EPUB and an audiobook alike: the dataless check is asked only
    /// inside a look that leaves dataless files in the cloud, so a look
    /// through a package iCloud Drive evicted whole is refused at once
    /// rather than bringing the book back down (board #624).
    func testEveryLookAtABooksFilesIsMadeWithDownloadingSwitchedOff() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in
                calls.note(downloadsAreSwitchedOffOnThisThread() ? "downloads off" : "downloads on")
                return false
            },
            readEPUBMetadata: { _ in epubFileMetadata },
            readAudioMetadata: { _ in AudioMetadata() }
        )
        let epub = try inAPackage(epubBook())
        let audiobook = try inAPackage(audioBook())

        _ = await reader.info(for: epub)
        _ = await reader.info(for: audiobook)

        XCTAssertEqual(calls.names, Array(repeating: "downloads off", count: 4))
    }

    /// An old book without a package is judged by its file alone.
    func testBookWithoutAPackageIsJudgedByItsFileAlone() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { url in calls.note("isDataless \(itemKind(url))"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )
        var book = epubBook()
        let file = try makeSandboxDirectory("Book Info Without A Package").appendingPathComponent("Middlemarch.epub")
        try Data("Not parsed by these tests.".utf8).write(to: file)
        book.filePath = file.path

        let info = await reader.info(for: book)

        guard case .epub(_, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(calls.names, ["isDataless file", "readEPUB"])
    }

    // MARK: - Other Formats and Saving

    /// Formats without the rich editor get the simple sheet without reading
    /// anything.
    func testOtherFormatsGetTheSimpleSheetWithoutReading() async {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in calls.note("isDataless"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )

        for format in BookFormat.allCases where !format.usesRichMetadataEditor {
            guard case .simple = await reader.info(for: cloudTestBook(format: format)) else {
                XCTFail("\(format) should get the simple sheet")
                continue
            }
        }
        XCTAssertEqual(calls.names, [])
    }

    /// Saving the edits of an EPUB that was only in the cloud into its file
    /// is refused with the reason, since writing would download it first;
    /// saving to the library only, or any book on this Mac, goes ahead.
    func testWritingACloudOnlyEPUBIsRefused() {
        XCTAssertEqual(
            LibraryBookInfo.writeRefusal(isCloudOnly: true, writesToFile: true),
            "The book's EPUB file is only in the cloud, so it can't be written until the book is downloaded. "
                + "Turn off writing to the file, or download the book first."
        )
        XCTAssertNil(LibraryBookInfo.writeRefusal(isCloudOnly: true, writesToFile: false))
        XCTAssertNil(LibraryBookInfo.writeRefusal(isCloudOnly: false, writesToFile: true))
    }

    // MARK: - Helpers

    /// An EPUB whose publisher was edited in the library.
    private func epubBook() -> Book {
        var book = cloudTestBook("Middlemarch", author: "George Eliot")
        book.epubPublisher = "Blackwood"
        book.epubLanguage = "en"
        return book
    }

    /// An audiobook an hour, 2 minutes, and 3 seconds long, whose album was
    /// edited in the library.
    private func audioBook() -> Book {
        var book = cloudTestBook("Bleak House", author: "Charles Dickens", format: .audio)
        book.audioAlbum = "Serial Edition"
        book.audioDuration = 3_723
        return book
    }

    /// `book` with its file, under the file's own name, in a package of its
    /// own, as the library keeps a book, in a library folder of the test's
    /// own that is removed when the test ends. The file holds a few bytes,
    /// which the tests' scripted reads never parse.
    private func inAPackage(_ book: Book) throws -> Book {
        var packaged = book
        packaged.folderPath = makeIntegrationLibraryFolder("Book Info").path
        packaged.tmbDirectoryName = "\(UUID().uuidString).tmb"
        let package = packaged.tmbDirectory
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent(book.bookFileURL.lastPathComponent)
        try Data("Not parsed by these tests.".utf8).write(to: file)
        packaged.filePath = file.path
        return packaged
    }
}

/// How the tests' scripted dataless checks name the item they are asked
/// about: "package" for a book's .tmb folder, and "file" for anything else.
private func itemKind(_ url: URL) -> String {
    url.pathExtension == "tmb" ? "package" : "file"
}

/// Whether the calling thread leaves dataless files in the cloud, as every
/// thread does inside `DatalessFiles.withoutDownloading(_:)`.
private func downloadsAreSwitchedOffOnThisThread() -> Bool {
    getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
}

/// What the tests' EPUB file says. It lives outside the main-actor test
/// class, so the readers' `@Sendable` closures can return it from any
/// thread.
private let epubFileMetadata = EPUBMetadata(
    title: "Middlemarch: A Study of Provincial Life",
    author: "Eliot, George",
    publisher: "Penguin Classics",
    publicationDate: "1871",
    isbn: "9780141439549",
    language: "en",
    identifier: "urn:isbn:9780141439549",
    epubVersion: "3.0"
)

/// The reads a test's `LibraryBookInfoReader` was asked for, in order, and
/// whether each ran on the main thread.
private final class ReadLog: @unchecked Sendable {
    /// Guards the entries: reads run on any thread.
    private let lock = NSLock()
    /// Each read's name and whether it ran on the main thread.
    private var entries: [(name: String, onMainThread: Bool)] = []

    /// Notes a read named `name`, on the thread it runs on.
    func note(_ name: String) {
        let onMainThread = Thread.isMainThread
        lock.withLock { entries.append((name: name, onMainThread: onMainThread)) }
    }

    /// The reads' names, in order.
    var names: [String] {
        lock.withLock { entries.map(\.name) }
    }

    /// Whether each read ran on the main thread, in order.
    var onMainThread: [Bool] {
        lock.withLock { entries.map(\.onMainThread) }
    }
}
