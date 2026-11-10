import XCTest
@testable import TextMouth

// MARK: - Cancelling an Import While an Own Reader Parses

/// TextMouth's own readers run on the import's own thread, with no child
/// process to kill, so a very large file used to be parsed to the end before
/// Cancel was heard. `ImportCancellation.throwIfCancelled()` is the one
/// check: the rich text reader asks it every few thousand tokens, and the
/// MOBI reader between its sections. A cancelled read throws
/// `ImportCancelled`, as a cancelled conversion by textutil does, and
/// leaves nothing behind.
final class OwnReaderCancellationTests: XCTestCase {

    /// A rich text document of about half a million tokens: many short
    /// paragraphs.
    private static let largeRichText: [UInt8] = {
        Array(("{\\rtf1\\ansi " + String(repeating: "word \\par ", count: 250_000) + "}").utf8)
    }()

    // MARK: - The check

    /// Outside an import there is no cancellation to hear: the check passes.
    func testTheCheckPassesOutsideAnImport() {
        XCTAssertNil(ImportCancellation.current)
        XCTAssertNoThrow(try ImportCancellation.throwIfCancelled())
    }

    /// Inside an import the check passes until the import is cancelled, and
    /// throws `ImportCancelled` from then on.
    func testTheCheckThrowsOnceTheImportIsCancelled() throws {
        let cancellation = ImportCancellation()
        try ImportCancellation.$current.withValue(cancellation) {
            XCTAssertNoThrow(try ImportCancellation.throwIfCancelled())
            cancellation.cancel()
            XCTAssertThrowsError(try ImportCancellation.throwIfCancelled()) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
        }
    }

    /// Another import's cancelled flag is not this one's: only the
    /// cancellation bound to the thread's import counts.
    func testACancelledImportOutsideTheBindingDoesNotStopThisOne() {
        let other = ImportCancellation()
        other.cancel()
        XCTAssertNoThrow(try ImportCancellation.throwIfCancelled())
    }

    // MARK: - Rich text

    /// The reader asks the check now and then, not once: half a million tokens
    /// are asked over a hundred times, and a read that is told to stop on its
    /// third look stops there, long before the document ends.
    func testTheRichTextReaderAsksAsItGoesAndStopsAtOnce() throws {
        let calls = CallCounter()
        var counting = RTFInterpreter(
            bytes: Self.largeRichText, includesPages: true, limit: DocumentByteLimit.standard,
            checkCancellation: { calls.count += 1 }
        )
        _ = try counting.read()
        XCTAssertGreaterThan(calls.count, 100, "A large document must be checked many times")

        let stopping = CallCounter()
        var interpreter = RTFInterpreter(
            bytes: Self.largeRichText, includesPages: true, limit: DocumentByteLimit.standard,
            checkCancellation: {
                stopping.count += 1
                if stopping.count == 3 { throw ImportCancelled() }
            }
        )
        XCTAssertThrowsError(try interpreter.read()) { error in
            XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
        }
        // One look before the first token, then one every interval: the read
        // stopped after two intervals, not at the end.
        XCTAssertEqual(stopping.count, 3)
    }

    /// A read of a large rich text file under an import that was cancelled
    /// throws `ImportCancelled` at once, whether it is read from bytes or
    /// from the file, and writes nothing into the folder of the file.
    func testACancelledRichTextReadThrowsAtOnceAndLeavesNothingBehind() throws {
        let folder = try makeSandboxDirectory("OwnReaderCancelRTF")
        let file = folder.appendingPathComponent("Large.rtf")
        try Data(Self.largeRichText).write(to: file)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)

        let cancellation = ImportCancellation()
        cancellation.cancel()
        let started = Date()
        try ImportCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(Self.largeRichText), includesPages: true)) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
            XCTAssertThrowsError(try RTFDocumentReader.html(of: file, as: .rtf, includesPages: true)) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "A cancelled read must not parse the file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), before)
    }

    /// An import that is bound but not cancelled reads as it always did.
    func testAnImportThatIsNotCancelledReadsNormally() throws {
        let cancellation = ImportCancellation()
        let html = try ImportCancellation.$current.withValue(cancellation) {
            try RTFDocumentReader.html(from: Data("{\\rtf1 Plain words.\\par}".utf8), includesPages: false)
        }
        XCTAssertTrue(html.contains("Plain words."), html)
    }

    /// Runs `work` on another thread as an import's read, cancels the import
    /// `delay` seconds after it began, and says what the read threw and how long
    /// it took to end once cancelled.
    private func cancelPartway(
        after delay: TimeInterval,
        _ work: @escaping @Sendable () throws -> Void
    ) -> (thrown: (any Error)?, secondsAfterCancel: TimeInterval) {
        // DIAGNOSTIC (cisuite): how long the same work takes uncancelled.
        let fullStart = Date()
        try? work()
        let fullSeconds = Date().timeIntervalSince(fullStart)
        let cancellation = ImportCancellation()
        let thrown = LockedValue<(any Error)?>(nil)
        let endedAt = LockedValue<Date?>(nil)
        let ended = expectation(description: "the read ended")
        DispatchQueue.global().async {
            ImportCancellation.$current.withValue(cancellation) {
                do {
                    try work()
                } catch {
                    thrown.value = error
                }
            }
            endedAt.value = Date()
            ended.fulfill()
        }
        Thread.sleep(forTimeInterval: delay)
        let cancelledAt = Date()
        cancellation.cancel()
        wait(for: [ended], timeout: 60)
        print("CANCELTIMING own full=\(fullSeconds) toEnd=\((endedAt.value ?? Date()).timeIntervalSince(cancelledAt))")
        return (thrown.value, (endedAt.value ?? Date()).timeIntervalSince(cancelledAt))
    }

    /// Cancel, pressed while a very large rich text file is being parsed, stops
    /// the parse within a moment, not at its end.
    func testCancelPartwayThroughALargeRichTextFileIsHeardAtOnce() {
        let bytes = Data(Self.largeRichText)
        let result = cancelPartway(after: 0.02) { _ = try RTFDocumentReader.html(from: bytes, includesPages: true) }
        XCTAssertEqual(result.thrown as? ImportCancelled, ImportCancelled(), "The read finished before Cancel, or failed")
        XCTAssertLessThan(result.secondsAfterCancel, 1.5)
    }

    // MARK: - Word documents

    /// A Word document of many paragraphs: about 600,000 elements.
    private func largeWordDocument() throws -> URL {
        let paragraphs = String(repeating: "<w:p><w:r><w:t>word</w:t></w:r></w:p>", count: 150_000)
        return try makeDOCXPackage(document: docxDocumentXML(paragraphs))
    }

    /// A Word document read under an import that was cancelled throws
    /// `ImportCancelled` before it reads a part, and leaves nothing beside the
    /// file; under one that is not, it reads.
    func testACancelledWordReadThrowsAtOnce() throws {
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("Some words"))))
        let folder = docx.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let running = ImportCancellation()
        let markdown = try ImportCancellation.$current.withValue(running) {
            try DOCXParser.extractMarkdown(from: docx, includesPages: false)
        }
        XCTAssertEqual(markdown, "Some words")
        let cancelled = ImportCancellation()
        cancelled.cancel()
        try ImportCancellation.$current.withValue(cancelled) {
            XCTAssertThrowsError(try DOCXParser.extractMarkdown(from: docx)) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), before)
    }

    /// Cancel, pressed while a very large Word document is being parsed, stops
    /// the parse within a moment, not at its end.
    func testCancelPartwayThroughALargeWordDocumentIsHeardAtOnce() throws {
        let docx = try largeWordDocument()
        let result = cancelPartway(after: 0.02) { _ = try DOCXParser.extractMarkdown(from: docx, includesPages: false) }
        XCTAssertEqual(result.thrown as? ImportCancelled, ImportCancelled(), "The read finished before Cancel, or failed")
        XCTAssertLessThan(result.secondsAfterCancel, 1.5)
    }

    // MARK: - The whole reading of a document

    /// The reading of a rich text file as the import runs it
    /// (`TextutilDocumentReader.extract`: the file's HTML, the parse of it, the
    /// conversion) ends with `ImportCancelled` under a cancelled import.
    func testTheWholeReadingOfARichTextDocumentIsCancelled() throws {
        let file = try copyOfFormatSample("rtf/word-styles.rtf")
        let cancelled = ImportCancellation()
        cancelled.cancel()
        try ImportCancellation.$current.withValue(cancelled) {
            XCTAssertThrowsError(try TextutilDocumentReader.extract(from: file, bookFormat: .rtf)) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
        }
        let running = ImportCancellation()
        let markdown = try ImportCancellation.$current.withValue(running) {
            try TextutilDocumentReader.extract(from: file, bookFormat: .rtf).markdown
        }
        XCTAssertTrue(markdown.contains("Chapter One"), markdown)
    }

    // MARK: - MOBI

    /// A Kindle book read under an import that was cancelled throws
    /// `ImportCancelled` and leaves nothing beside the file; the same book
    /// reads when the import is not cancelled.
    func testACancelledMOBIReadThrowsAndLeavesNothingBehind() throws {
        let book = try copyOfFormatSample("mobi/ferry-notes-ncx.mobi")
        let folder = book.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)

        let running = ImportCancellation()
        let prepared = try ImportCancellation.$current.withValue(running) {
            try MOBIParser.prepareBook(url: book)
        }
        XCTAssertFalse(prepared.chapters.isEmpty)

        let cancelled = ImportCancellation()
        cancelled.cancel()
        try ImportCancellation.$current.withValue(cancelled) {
            XCTAssertThrowsError(try MOBIParser.prepareBook(url: book)) { error in
                XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), before)
    }
}

/// A count a closure bumps, held in a class so the closure can be
/// `@escaping` and the test can read it afterwards.
private final class CallCounter {
    var count = 0
}
