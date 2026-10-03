import Foundation
import XCTest
@testable import TextMouth

/// The library's Book Info reads a book's metadata off the main thread, and
/// never downloads a book whose file is only in the cloud: for that book it
/// shows the metadata the library keeps, with a note that some details
/// appear once the book is downloaded (FR02).
@MainActor
final class LibraryCloudBookInfoTests: XCTestCase {
    // MARK: - EPUB

    /// An EPUB on this Mac is read off the main thread, and the library's
    /// own edits are laid over what the file says.
    func testEPUBMetadataIsReadOffTheMainThread() async throws {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in calls.note("isDataless"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )

        let info = await reader.info(for: epubBook())

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch", "the library's title wins")
        XCTAssertEqual(metadata.publisher, "Blackwood", "the library's publisher wins")
        XCTAssertEqual(metadata.isbn, "9780141439549", "the file's ISBN shows")
        XCTAssertEqual(calls.names, ["isDataless", "readEPUB"])
        XCTAssertEqual(calls.onMainThread, [false, false])
    }

    /// An EPUB only in the cloud is not read at all: Book Info shows the
    /// metadata the library keeps, and says the rest comes with the download.
    func testCloudOnlyEPUBShowsTheLibrarysMetadataWithoutReading() async {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in calls.note("isDataless"); return true },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )

        let info = await reader.info(for: epubBook())

        guard case .epub(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the EPUB editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Middlemarch")
        XCTAssertEqual(metadata.author, "George Eliot")
        XCTAssertEqual(metadata.publisher, "Blackwood")
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.isbn, "", "the library keeps no ISBN for this book")
        XCTAssertEqual(calls.names, ["isDataless"], "the file is never read")
        XCTAssertEqual(LibraryBookInfo.cloudOnlyNote, "Some details appear once the book is downloaded.")
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
    func testAudioMetadataIsReadOffTheMainThread() async {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in calls.note("isDataless"); return false },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in
                calls.note("readAudio")
                return AudioMetadata(title: "Tag Title", artist: "Tag Artist", album: "Tag Album", duration: "9:41", fileFormat: "M4B")
            }
        )

        let info = await reader.info(for: audioBook())

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertFalse(isCloudOnly)
        XCTAssertEqual(metadata.title, "Bleak House")
        XCTAssertEqual(metadata.artist, "Charles Dickens")
        XCTAssertEqual(metadata.album, "Serial Edition", "the library's album wins")
        XCTAssertEqual(metadata.duration, "9:41", "the file's length shows")
        XCTAssertEqual(calls.names, ["isDataless", "readAudio"])
        XCTAssertEqual(calls.onMainThread, [false, false])
    }

    /// An audiobook only in the cloud is not read: Book Info shows the
    /// library's names, its measured length, and its file's type.
    func testCloudOnlyAudiobookShowsTheLibrarysMetadataWithoutReading() async {
        let calls = ReadLog()
        let reader = LibraryBookInfoReader(
            isDataless: { _ in calls.note("isDataless"); return true },
            readEPUBMetadata: { _ in calls.note("readEPUB"); return epubFileMetadata },
            readAudioMetadata: { _ in calls.note("readAudio"); return AudioMetadata() }
        )

        let info = await reader.info(for: audioBook())

        guard case .audio(let metadata, let isCloudOnly) = info else {
            return XCTFail("expected the audio editor, got \(info)")
        }
        XCTAssertTrue(isCloudOnly)
        XCTAssertEqual(metadata.title, "Bleak House")
        XCTAssertEqual(metadata.album, "Serial Edition")
        XCTAssertEqual(metadata.duration, "1:02:03")
        XCTAssertEqual(metadata.fileFormat, "M4B")
        XCTAssertEqual(calls.names, ["isDataless"], "the file is never read")
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
