import XCTest
@testable import TextMouth

/// RTF, RTFD, Word 97-2003, OpenDocument text, and Word 2003 XML documents
/// import as books through textutil (FMT13): each format sample, imported
/// from a copy in a folder of the test's own, opens with its headings and
/// text; refusals say what is wrong in the listener's words and leave
/// nothing behind; and no run of textutil leaves a hidden file anywhere.
final class TextutilImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the refusal tests import into; each test has its own.
    private let folderPath = "Textutil Import \(UUID().uuidString.prefix(8))"
    /// The folder this test's conversions make their working folders in
    /// (`TextutilDocumentReader.temporaryRoot`), so its scan for leftovers
    /// never meets those of another build's textutil, which the shared
    /// temporary directory would show it. Replaced in set-up.
    private var temporaryRoot = URL(fileURLWithPath: "/var/empty", isDirectory: true)

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        temporaryRoot = try makeSandboxDirectory("TextutilTemporaryRoot")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - Helpers

    /// What one sample should import as and show.
    private struct Expectation {
        /// The sample's path inside `TestData/format-samples`.
        var sample: String
        /// The name the copy is given, or nil to keep the sample's own.
        var copyName: String?
        var format: BookFormat
        /// The title and author the book is listed under.
        var title: String
        var author: String = Book.unknownAuthor
        /// Every heading the reader shows, as "level: text", in order.
        var headings: [String]
        /// Words that must be in the text, and words that must not.
        var contains: [String] = []
        var excludes: [String] = []
    }

    /// Imports a copy of the sample `expected` names and asserts everything
    /// it says: the format, the title and author, every heading with its
    /// level, and the words present and absent.
    private func assertImports(_ expected: Expectation, file: StaticString = #filePath, line: UInt = #line) throws {
        let copy = try copyOfFormatSample(expected.sample, named: expected.copyName)
        let imported = try importedForTest(copy)
        let book = imported.book
        let label = expected.sample

        XCTAssertEqual(book.format, expected.format, label, file: file, line: line)
        XCTAssertEqual(book.title, expected.title, label, file: file, line: line)
        XCTAssertEqual(book.author, expected.author, label, file: file, line: line)

        let content = try openedContent(of: book)
        XCTAssertEqual(headingLines(of: content), expected.headings, label, file: file, line: line)
        let text = allText(of: content)
        for word in expected.contains {
            XCTAssertTrue(text.contains(word), "\(label) lacks “\(word)”", file: file, line: line)
        }
        for word in expected.excludes {
            XCTAssertFalse(text.contains(word), "\(label) holds “\(word)”", file: file, line: line)
        }
        // A successful import leaves no hidden file of textutil's in its package.
        XCTAssertEqual(textutilFiles(under: book.tmbDirectory), [], label, file: file, line: line)
    }

    /// The paths, relative to `folder`, of the hidden files textutil writes
    /// (`TextutilConverter.temporarySuffix`) anywhere inside it.
    private func textutilFiles(under folder: URL) -> [String] {
        let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return paths.filter { $0.hasSuffix(TextutilConverter.temporarySuffix) }.sorted()
    }

    /// Every textutil leftover in the places a conversion could write: the
    /// import staging folder, and this test's temporary root (the hidden
    /// file, and the folders `TextutilDocumentReader` makes there).
    private func textutilLeftovers() -> Set<String> {
        var found = Set<String>()
        for path in textutilFiles(under: MachineLocalPaths.importStaging) {
            found.insert("staging/\(path)")
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        where name.hasPrefix("TextMouth-textutil-") || name.hasSuffix(TextutilConverter.temporarySuffix) {
            found.insert("temporary/\(name)")
        }
        return found
    }

    /// Runs `body`, its conversions working in this test's temporary root,
    /// and asserts that it left no textutil file in any place a conversion
    /// could write (the leftovers present before are ignored, so a sibling
    /// process's run in the shared staging folder never fails this test).
    private func assertLeavesNoTextutilFiles(
        file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) throws {
        let before = textutilLeftovers()
        try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
            try body()
        }
        XCTAssertEqual(textutilLeftovers().subtracting(before), [], file: file, line: line)
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist. A refused import leaves it empty.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Asserts that importing `url` into this test's library folder fails
    /// with exactly `sentence` (the import's own words, including the file's
    /// name), leaving nothing in the library and no textutil file anywhere.
    private func assertRefused(
        _ url: URL, saying sentence: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertLeavesNoTextutilFiles(file: file, line: line) {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url, toFolder: folderPath), file: file, line: line) {
                XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
            }
        }
        XCTAssertEqual((try? folderEntries()) ?? ["unreadable"], [], file: file, line: line)
    }

    /// A file named `name` in a new folder of this test's own, holding `bytes`.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("TextutilImport").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Samples: Rich Text

    func testRichTextSamplesImportWithTheirHeadings() throws {
        try assertImports(Expectation(
            sample: "rtf/headings.rtf", format: .rtf, title: "headings", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard", "Departs"]
        ))
        try assertImports(Expectation(
            sample: "rtf/word-styles.rtf", format: .rtf, title: "Word Styles Sample", author: "A. Sample",
            // The paragraph with outline level 3 but no heading style is a heading too.
            headings: [
                "1: Chapter One: The Quay", "2: Morning Tides",
                "3: A paragraph with outline level 3 but no heading style", "3: A third-level heading",
            ],
            contains: ["The last paragraph is plain."]
        ))
        try assertImports(Expectation(
            sample: "rtf/word-list-table.rtf", format: .rtf, title: "List and Table", author: "A. Sample",
            headings: ["1: Shopping and Timetable", "2: Shopping", "2: Timetable"],
            contains: ["Bread from the bakery", "After the table."]
        ))
    }

    func testRichTextWithAttachmentsImportsAndKeepsItsFolder() throws {
        try assertImports(Expectation(
            sample: "rtfd/headings.rtfd", format: .rtfd, title: "headings", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard"]
        ))
        try assertImports(Expectation(
            sample: "rtfd/with-image.rtfd", format: .rtfd, title: "with-image",
            headings: ["1: The Pier"],
            contains: ["After the picture, the text goes on."],
            excludes: ["Attachment"]
        ))

        // The package holds the .rtfd folder whole, picture and all.
        let book = try importedForTest(try copyOfFormatSample("rtfd/with-image.rtfd")).book
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.bookFileURL.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertEqual(book.bookFileURL.lastPathComponent, "with-image.rtfd")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: book.bookFileURL.path)),
            Set(try FileManager.default.contentsOfDirectory(atPath: try formatSampleURL("rtfd/with-image.rtfd").path))
        )
    }

    // MARK: - Samples: Word and OpenDocument

    func testWordSamplesImportAsDocWhateverTheirTemplateBit() throws {
        let harbour = ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
        for sample in ["doc/headings.doc", "dot/headings-synthetic.dot"] {
            try assertImports(Expectation(
                sample: sample, format: .doc, title: String(sample.dropFirst(4).dropLast(4)), author: "A. Sample",
                headings: harbour,
                contains: ["Bread from the bakery on Rue Ménard", "A newspaper already a day old"],
                excludes: ["•"]
            ))
        }
        try assertImports(Expectation(
            sample: "dot/libreoffice-tdf120761_zOrder.dot", format: .doc, title: "libreoffice-tdf120761_zOrder",
            headings: [], contains: ["Blah blah blah"]
        ))
        try assertImports(Expectation(
            sample: "doc/libreoffice-tdf104239_chapterNumbering.doc", format: .doc,
            title: "libreoffice-tdf104239_chapterNumbering",
            headings: ["1: Heading 1", "2: Heading 2", "3: Heading 3", "4: Heading 4", "5: Heading 5", "5: Heading 6"]
        ))
        try assertImports(Expectation(
            sample: "doc/libreoffice-tdf81705_outlineLevel.doc", format: .doc,
            title: "libreoffice-tdf81705_outlineLevel", author: "user", headings: ["1: Contents"]
        ))
    }

    func testOpenDocumentSamplesImportAsODTWhateverTheirTemplateName() throws {
        let harbour = ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
        try assertImports(Expectation(
            sample: "odt/handwritten.odt", format: .odt, title: "Harbour Notes", headings: harbour,
            contains: ["Bread from the bakery on Rue Ménard"]
        ))
        try assertImports(Expectation(
            sample: "odt/headings.odt", format: .odt, title: "headings", author: "A. Sample", headings: harbour,
            contains: ["A newspaper already a day old"]
        ))
        try assertImports(Expectation(
            sample: "ott/handwritten.ott", format: .odt, title: "Harbour Notes", headings: harbour
        ))
    }

    /// A WordML file is an .xml file, known by its root element. Its table
    /// comes back flattened, so its bold header cells ("Boat", "Departs")
    /// read as headings: what the reader shows is pinned as it is.
    func testWordMLImportsUnderAnXMLName() throws {
        try assertImports(Expectation(
            sample: "wordml/headings.wordml", copyName: "headings.xml", format: .wordml, title: "headings",
            author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable", "3: Boat", "3: Departs"],
            contains: ["Bread from the bakery on Rue Ménard"], excludes: ["•"]
        ))
    }

    /// textutil writes the title and author of some real Word files as NUL
    /// characters: the listener meets the file's name and an unknown author,
    /// or the part of the author that is text, never control characters.
    func testControlCharactersInAWordDocumentsMetadataAreDropped() throws {
        let nulTitle = try copyOfFormatSample("dot/libreoffice-tdf120761_zOrder.dot")
        let none = try TextutilDocumentReader.readMetadata(from: nulTitle, bookFormat: .doc)
        XCTAssertEqual(none.title, "")
        XCTAssertEqual(none.author, "")
        let parsed = try TextutilDocumentReader.parse(url: nulTitle, bookFormat: .doc)
        XCTAssertEqual(parsed.title, "libreoffice-tdf120761_zOrder")
        XCTAssertEqual(parsed.author, Book.unknownAuthor)

        let nulAuthor = try copyOfFormatSample("doc/libreoffice-tdf81705_outlineLevel.doc")
        let user = try TextutilDocumentReader.readMetadata(from: nulAuthor, bookFormat: .doc)
        XCTAssertEqual(user.title, "")
        XCTAssertEqual(user.author, "user")
    }

    /// An RTF file named .doc imports as a .doc and reads as the RTF does.
    func testRTFNamedDocReadsAsRTF() throws {
        try assertImports(Expectation(
            sample: "rtf/headings.rtf", copyName: "notes.doc", format: .doc, title: "notes", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard", "Departs"]
        ))
    }

    // MARK: - An Import's Cancel Stops textutil

    /// What a test's queued import threw, set on the import queue's thread
    /// and read on the test's.
    private let thrown = LockedValue<(any Error)?>(nil)

    /// Queues the import of `url` on `queue`, converting through `tool`, and
    /// returns an expectation fulfilled when the import ends; `thrown` holds
    /// what it threw, if anything.
    private func queueImport(of url: URL, on queue: SerialImportQueue, using tool: TextutilConverter.Tool) -> XCTestExpectation {
        let ended = expectation(description: "the import ended")
        let folderPath = folderPath
        let thrown = thrown
        queue.enqueue {
            do {
                // The stand-in tool is bound here, on the queue's own thread.
                _ = try TextutilConverter.$tool.withValue(tool) {
                    try FileImportService.importFileWithReport(from: url, toFolder: folderPath)
                }
            } catch {
                thrown.value = error
            }
            ended.fulfill()
        }
        return ended
    }

    /// The import queue's Cancel kills the textutil child an import waits
    /// for, within a second or two: the import ends as a cancelled import
    /// does (`ImportCancelled`, no failure), nothing is left in the library
    /// or the staging folder, no child runs, and a conversion made outside
    /// an import afterwards is not stopped.
    func testCancellingTheQueueStopsARunningTextutilAndLeavesNothing() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        let queue = SerialImportQueue()
        let childrenBefore = WatchedProcess.runningChildCount

        try assertLeavesNoTextutilFiles {
            let ended = queueImport(of: copy, on: queue, using: recorder.hangingTool())
            let started = Date().addingTimeInterval(10)
            while WatchedProcess.runningChildCount <= childrenBefore, Date() < started {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertGreaterThan(WatchedProcess.runningChildCount, childrenBefore, "The child never started")

            let cancelledAt = Date()
            queue.cancelEnqueued()
            wait(for: [ended], timeout: 5)
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        }

        XCTAssertTrue(thrown.value is ImportCancelled, "\(String(describing: thrown.value))")
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        XCTAssertEqual(try folderEntries(), [])

        // The cancel was the import's: a reader's conversion is not stopped.
        let named = try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
            try TextutilDocumentReader.readMetadata(from: copy, bookFormat: .rtf)
        }
        XCTAssertEqual(named.author, "A. Sample")
    }

    /// An import cancelled while it waits behind another never starts its
    /// child: it ends cancelled as soon as its turn comes.
    func testAnImportCancelledWhileItWaitsStartsNoChild() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        let queue = SerialImportQueue()
        let childrenBefore = WatchedProcess.runningChildCount

        // A first import holds the queue until the test lets it go.
        let gate = DispatchSemaphore(value: 0)
        let firstEnded = expectation(description: "the first import ended")
        queue.enqueue {
            gate.wait()
            firstEnded.fulfill()
        }
        let ended = queueImport(of: copy, on: queue, using: recorder.hangingTool())
        queue.cancelEnqueued()
        gate.signal()
        wait(for: [firstEnded, ended], timeout: 5)

        XCTAssertTrue(thrown.value is ImportCancelled, "\(String(describing: thrown.value))")
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A ZIP batch whose book is cancelled mid-conversion stops there, as it
    /// stops between books: the cancelled book is no failure, and the
    /// books before it are kept.
    func testABatchStopsWhereABookWasCancelledMidConversion() throws {
        let files = [URL(fileURLWithPath: "/tmp/one.rtf"), URL(fileURLWithPath: "/tmp/two.rtf"), URL(fileURLWithPath: "/tmp/three.rtf")]
        let result = FileImportService.importSupportedFiles(
            files,
            toFolder: "",
            checksum: { $0.lastPathComponent },
            importer: { url, _, _, _ in
                // The second book is the one the cancel catches.
                if url.lastPathComponent == "two.rtf" { throw ImportCancelled() }
                return ImportedBook(book: Book(title: url.lastPathComponent, format: .rtf, filePath: url.path, md5Hash: url.lastPathComponent))
            }
        )
        XCTAssertEqual(result.books.map(\.title), ["one.rtf"])
        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.cancellation, .afterBooks(completed: 1, total: 3))
    }

    /// An import the reader cancelled raises no alert, and one that failed does.
    @MainActor
    func testACancelledImportRaisesNoAlertButAFailedOneDoes() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let model = LibraryViewModel(initializeServices: false)
        let queue = model.importOperationQueue
        // The import fails (or is cancelled) as it begins to copy the file.
        let failure = LockedValue<(any Error)?>(ImportCancelled())
        queue.stepObserver = { step, _ in
            if step == .copying, let error = failure.value { throw error }
        }
        addTeardownBlock { queue.stepObserver = nil }

        /// Waits until the import queued before has ended and the main queue
        /// has run what that import left on it.
        func settle() {
            let settled = expectation(description: "the queue settled")
            model.enqueueImport { DispatchQueue.main.async { settled.fulfill() } }
            wait(for: [settled], timeout: 10)
        }

        model.importSingleFileAsync(from: copy, toFolder: folderPath)
        settle()
        XCTAssertFalse(model.showError)

        failure.value = FileImportError.noTextToRead
        model.importSingleFileAsync(from: copy, toFolder: folderPath)
        settle()
        XCTAssertTrue(model.showError)
        XCTAssertTrue((model.errorMessage ?? "").contains("This file has no text to read."), model.errorMessage ?? "nil")
    }

    // MARK: - Refusals

    /// Every sentence is what the listener hears: the import's own words,
    /// the file's name, the step, then the reason.
    func testRefusalsReadWordForWord() throws {
        // A Word document with the encrypted bit set.
        let word = try copyOfFormatSample("doc/headings.doc")
        let offset = try fibOffset(of: word)
        try setFibFlags(try fibFlags(of: word, at: offset) | 0x0100, of: word, at: offset)
        let password = "This document is protected by a password. Save a copy without the password, then import that copy."
        try assertRefused(word, saying: "Could not import “headings.doc”. Reading its text failed: \(password)")

        // An OpenDocument text file with encryption data in its manifest.
        let open = try copyOfFormatSample("odt/handwritten.odt")
        try replaceManifest(in: open, with: encryptedManifest)
        try assertRefused(open, saying: "Could not import “handwritten.odt”. Reading its text failed: \(password)")

        // Random bytes named .doc.
        let random = try file(named: "random.doc", holding: Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        try assertRefused(random, saying: "Could not import “random.doc”. Reading its text failed: "
            + "This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file.")

        // Nothing, and only white space.
        let noText = "Reading its text failed: This file has no text to read."
        try assertRefused(try file(named: "empty.rtf", holding: Data()), saying: "Could not import “empty.rtf”. \(noText)")
        try assertRefused(
            try file(named: "blank.rtf", holding: Data(#"{\rtf1\ansi \par \par }"#.utf8)),
            saying: "Could not import “blank.rtf”. \(noText)"
        )
    }

    func testAnRTFPastTheByteLimitIsRefused() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        try assertLeavesNoTextutilFiles {
            XCTAssertThrowsError(
                try DocumentByteLimit.$current.withValue(100) {
                    try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
                }
            ) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Could not import “headings.rtf”. Reading its text failed: "
                        + "This document holds more than 100 bytes, the most TextMouth reads from one document."
                )
            }
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - Where Conversions Work

    /// A conversion outside a staged package (a reader's load, the launch
    /// refresh) works in a new folder of `temporaryRoot`, which a test binds
    /// to a folder of its own, and removes it: the root is empty after.
    func testAConversionOutsideAStagedPackageWorksInTheBoundRoot() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        let named = try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
            try TextutilConverter.$tool.withValue(recorder.countingTool()) {
                try TextutilDocumentReader.readMetadata(from: copy, bookFormat: .rtf)
            }
        }
        XCTAssertEqual(named.author, "A. Sample")

        // The hidden file went in one working folder made directly in the root.
        let outputs = recorder.outputs
        XCTAssertEqual(outputs.count, 1)
        let working = try XCTUnwrap(outputs.first).deletingLastPathComponent()
        XCTAssertTrue(working.lastPathComponent.hasPrefix("TextMouth-textutil-"), working.lastPathComponent)
        XCTAssertEqual(
            working.deletingLastPathComponent().resolvingSymlinksInPath().path,
            temporaryRoot.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
    }

    // MARK: - Nothing Left Behind

    func testASuccessfulImportLeavesNoTextutilFileAnywhere() throws {
        try assertLeavesNoTextutilFiles {
            for sample in ["rtf/headings.rtf", "rtfd/headings.rtfd", "doc/headings.doc", "odt/handwritten.odt"] {
                _ = try importedForTest(try copyOfFormatSample(sample))
            }
        }
    }

    /// Regenerating the text of an imported RTF and of an imported RTFD
    /// gives the same headings and leaves nothing in the package or the
    /// temporary directory.
    func testRegeneratingTheTextOfRTFAndRTFDLeavesNothing() throws {
        for sample in ["rtf/headings.rtf", "rtfd/headings.rtfd"] {
            let book = try importedForTest(try copyOfFormatSample(sample)).book
            let before = headingLines(of: try openedContent(of: book))
            XCTAssertFalse(before.isEmpty, sample)

            try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: book))
            try assertLeavesNoTextutilFiles {
                let regenerated = try BookContentAnalysisService.load(book: book, regenerateTextCache: true).content
                XCTAssertEqual(headingLines(of: regenerated), before, sample)
            }
            XCTAssertEqual(textutilFiles(under: book.tmbDirectory), [], sample)
            XCTAssertTrue(MarkdownCacheService.cacheExists(for: book), sample)
        }
    }

    // MARK: - The Cases

    func testTheNewFormatsKeepTheirRawValuesAndNames() {
        XCTAssertEqual(BookFormat(rawValue: "rtf"), .rtf)
        XCTAssertEqual(BookFormat(rawValue: "rtfd"), .rtfd)
        XCTAssertEqual(BookFormat(rawValue: "doc"), .doc)
        XCTAssertEqual(BookFormat(rawValue: "odt"), .odt)
        XCTAssertEqual(BookFormat(rawValue: "wordml"), .wordml)

        XCTAssertEqual(BookFormat.rtf.displayName, "Rich Text")
        XCTAssertEqual(BookFormat.rtfd.displayName, "Rich Text with Attachments")
        XCTAssertEqual(BookFormat.doc.displayName, "Word 97-2003 Document")
        XCTAssertEqual(BookFormat.odt.displayName, "OpenDocument Text")
        XCTAssertEqual(BookFormat.wordml.displayName, "Word 2003 XML")

        XCTAssertEqual(BookFormat.doc.fileExtensions, ["doc", "dot"])
        XCTAssertEqual(BookFormat.odt.fileExtensions, ["odt", "ott"])
        XCTAssertEqual(BookFormat.wordml.fileExtensions, [])
    }

    func testABookOfEachNewFormatEncodesAndDecodesWithItsFormat() throws {
        for format in [BookFormat.rtf, .rtfd, .doc, .odt, .wordml] {
            let book = Book(title: "Pier", format: format, filePath: "/tmp/pier", md5Hash: "hash")
            let data = try JSONEncoder().encode(book)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(format.rawValue)\""), format.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(Book.self, from: data).format, format)
        }
    }

    func testEachExtensionIsDetectedAndAnXMLFileIsKnownByItsRoot() throws {
        for (name, format) in [("a.rtf", BookFormat.rtf), ("a.RTFD", .rtfd), ("a.doc", .doc), ("a.dot", .doc),
                               ("a.odt", .odt), ("a.ott", .odt)] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/\(name)")), format, name)
        }
        XCTAssertEqual(BookFormat.detect(from: try copyOfFormatSample("wordml/headings.wordml", named: "headings.xml")), .wordml)
        XCTAssertEqual(BookFormat.detect(from: try copyOfFormatSample("dtbook/harbour-standalone.xml")), .daisy)
        // WordML under its own name has no extension that says what it is.
        XCTAssertNil(BookFormat.detect(from: try copyOfFormatSample("wordml/headings.wordml")))
    }

    // MARK: - The Checksum of a Folder

    /// An RTFD's checksum is that of its files: stable, changed by a change
    /// in its text, unchanged by a hidden file, and never a thrown error.
    func testAnRTFDChecksumIsStableAndFollowsItsFiles() throws {
        let copy = try copyOfFormatSample("rtfd/with-image.rtfd")
        let first = try FileImportService.importHash(of: copy)
        XCTAssertEqual(try FileImportService.importHash(of: copy), first)
        XCTAssertEqual(first.count, 32)

        // Finder's mark of a visit changes nothing.
        try Data("x".utf8).write(to: copy.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try FileImportService.importHash(of: copy), first)

        // A change in the text does.
        let text = copy.appendingPathComponent("TXT.rtf")
        try (try Data(contentsOf: text) + Data(" ".utf8)).write(to: text)
        XCTAssertNotEqual(try FileImportService.importHash(of: copy), first)
    }

    /// The checksum recorded for an imported RTFD is the one of its file
    /// in the package, which a package import compares.
    func testAnImportedRTFDIsKnownByTheChecksumOfItsFolder() throws {
        let book = try importedForTest(try copyOfFormatSample("rtfd/headings.rtfd")).book
        XCTAssertEqual(try FileImportService.importHash(of: book.bookFileURL), book.md5Hash)
    }

    /// A folder never reaches `FileHandle`, whose legacy read raises an
    /// exception that cannot be caught: every reader of a book's file
    /// refuses or skips one.
    func testNoReaderOfABookFileRaisesOnAFolder() throws {
        let folder = try copyOfFormatSample("rtfd/headings.rtfd")
        XCTAssertThrowsError(try FileImportService.md5Hash(of: folder))
        XCTAssertNil(FileStamp(of: folder))
        XCTAssertNil(FileFingerprint(of: folder, hasher: .md5))
        XCTAssertThrowsError(try FingerprintHasher.md5.digestOfFile(folder))
        XCTAssertThrowsError(try ContentFingerprint(of: folder))
    }

    /// A plain file named .rtfd is hashed as a file, not walked as a folder.
    func testAFileNamedRTFDIsHashedAsAFile() throws {
        let plain = try file(named: "plain.rtfd", holding: Data("not a folder".utf8))
        XCTAssertEqual(try FileImportService.importHash(of: plain), try FileImportService.md5Hash(of: plain))
    }
}

// MARK: - A Stand-In for textutil

/// Stands in for the tool of `TextutilConverter` in a test: it records where
/// each conversion was told to write, then runs real textutil (`countingTool()`)
/// or a child that never ends (`hangingTool()`). Its list is the conversions
/// an operation made.
final class TextutilToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    /// The hidden output file of each conversion started, in order.
    var outputs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Notes one conversion that will write `output`.
    private func record(_ output: URL) {
        lock.lock()
        recorded.append(output)
        lock.unlock()
    }

    /// Real textutil under its own limits, with each run recorded.
    func countingTool() -> TextutilConverter.Tool {
        let real = TextutilConverter.Tool.textutil
        return TextutilConverter.Tool(
            command: { [self] input, format, output in
                record(output)
                return real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
    }

    /// A child that sleeps for a minute and writes nothing, with each run
    /// recorded: only its being killed ends it early. Its limits are loose,
    /// so the watchdog never ends it within a test.
    func hangingTool() -> TextutilConverter.Tool {
        TextutilConverter.Tool(
            command: { [self] _, _, output in
                record(output)
                return (URL(fileURLWithPath: "/bin/sleep"), ["60"])
            },
            limits: { _ in
                WatchedProcess.Limits(
                    maximumSeconds: 120, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 120, pollInterval: 0.1
                )
            },
            residentMemory: { _ in nil }
        )
    }
}
