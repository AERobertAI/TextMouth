import XCTest
@testable import TextMouth

/// Import questions are queued, never replaced (TODO I01).
///
/// Imports finish one after another and go on while a question waits. The
/// library used to keep one duplicate, one original file, and one ZIP batch
/// waiting for an answer, so a second import's question took the first's
/// place: the first question was never asked, an answer could land on the
/// wrong file, a duplicate's package was left on disk outside the library,
/// and a book opened from Finder never opened once its duplicate was kept.
/// The first five tests are that reproduction, now answered; with the single
/// pending question restored they fail in exactly those ways.
///
/// Each test imports real files through the library's own import queue, as
/// Open Book... does, into a library folder of its own, then answers as the
/// question sheet's buttons do. No test waits a fixed time: each waits for
/// the import queue, then the main queue, to run what was queued before.
@MainActor
final class ImportDecisionFlowTests: XCTestCase {

    // MARK: - The Reproduction, Answered

    /// Two copies of books already in the library are imported together.
    /// Each copy is asked about, the first first, and keeping both copies
    /// each time adds both; nothing imported is left outside the library.
    func testTwoDuplicatesAreBothAskedInOrder() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing, bestiary.existing])
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(waitingQuestions(of: scene.model), ["duplicate: Atlas of Tides", "duplicate: Bestiary of Knots"])
        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.existing.id, atlas.existing.id)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        XCTAssertEqual(
            scene.model.importDecisions.current?.duplicate?.existing.id, bestiary.existing.id,
            "the second copy's question is gone"
        )
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)

        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        XCTAssertEqual(
            titles(in: scene.folder.path, of: scene.model),
            [atlas.existing.title, bestiary.existing.title, "Atlas of Tides", "Bestiary of Knots"]
        )
        XCTAssertEqual(
            try scene.folder.entries(), Set(scene.model.library.books.map(\.tmbDirectoryName)),
            "an imported copy was left on disk outside the library"
        )
    }

    /// While the user reads the first copy's question, a second copy
    /// finishes. The question being asked stays the first copy's, and
    /// Replace replaces the book the first copy matches, never the second's.
    func testAnAnswerAppliesToTheFileItWasAskedAbout() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing, bestiary.existing])
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let asked = try XCTUnwrap(scene.model.importDecisions.current)
        scene.model.importFiles(urls: [bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(scene.model.importDecisions.current?.id, asked.id, "the question changed while it was being read")
        XCTAssertTrue(scene.model.answerImportDecision(asked.id, with: .replaceExisting).succeeded)

        let library = titles(in: scene.folder.path, of: scene.model)
        XCTAssertFalse(library.contains(atlas.existing.title), "Replace did not replace the book the first copy matches")
        XCTAssertTrue(library.contains(bestiary.existing.title), "Replace replaced the second copy's match")
        XCTAssertTrue(library.contains("Atlas of Tides"))
        XCTAssertEqual(waitingQuestions(of: scene.model), ["duplicate: Bestiary of Knots"])
    }

    /// Two files imported while "After Importing a Book" asks each time are
    /// each offered for deletion, the first first, and each answer reaches
    /// its own file.
    func testEveryOriginalIsOfferedForDeletionInOrder() throws {
        let scene = try makeScene()
        let atlas = try writeSource("Atlas of Tides", in: scene)
        let bestiary = try writeSource("Bestiary of Knots", in: scene)
        useAfterImportingBehavior(.askEachTime)

        scene.model.importFiles(urls: [atlas, bestiary], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(
            waitingQuestions(of: scene.model),
            ["original: Atlas of Tides.txt", "original: Bestiary of Knots.txt"]
        )
        scene.model.answerCurrentImportDecision(.deleteOriginal)
        scene.model.answerCurrentImportDecision(.cancel)

        XCTAssertFalse(FileManager.default.fileExists(atPath: atlas.path), "Delete did not reach the first file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bestiary.path), "Keep did not reach the second file")
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    /// Two ZIP archives of two books each are each offered a folder, the
    /// first archive first, and each answer moves its own books only.
    func testEveryMultiBookZIPIsOfferedAFolderInOrder() throws {
        let scene = try makeScene()
        let first = try writeArchive("First Shelf", titles: ["Atlas of Tides", "Bestiary of Knots"], in: scene)
        let second = try writeArchive("Second Shelf", titles: ["Charts of Shoals", "Dredging Logs"], in: scene)
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importFiles(urls: [first, second], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(waitingQuestions(of: scene.model), ["folder: First Shelf.zip", "folder: Second Shelf.zip"])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.createFolder(named: "First Shelf")).succeeded)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)

        let shelf = BookFolder(name: "First Shelf", parentPath: scene.folder.path).fullPath
        XCTAssertEqual(titles(in: shelf, of: scene.model), ["Atlas of Tides", "Bestiary of Knots"])
        XCTAssertEqual(titles(in: scene.folder.path, of: scene.model), ["Charts of Shoals", "Dredging Logs"])
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    /// A duplicate opened from Finder opens once the user keeps it, and not
    /// before.
    func testADuplicateOpenedFromFinderOpensOnceKept() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)

        // The path an item opened from Finder takes (`importAndOpenFiles`).
        scene.model.importSingleFileAsync(from: atlas.copy, toFolder: scene.folder.path, openAfterImport: true)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        XCTAssertEqual(scene.opened.ids, [], "the book opened before its question was answered")
        scene.model.answerCurrentImportDecision(.keepBoth)

        XCTAssertEqual(scene.opened.ids, [copy.id])
    }

    /// A WebVTT file opened from Finder (or the Dock) together with the audio
    /// it sits beside is not refused as a book: the audio's import attaches it,
    /// and the import shows no error. Opened without the audio, it is refused
    /// as before.
    func testATranscriptOpenedFromFinderWithItsAudioIsAttachedNotRefused() throws {
        let scene = try makeScene()
        useAfterImportingBehavior(.keepOriginal)
        let audio = scene.sources.appendingPathComponent("Tide.wav")
        try AudioTestFixtures.writeSilence(to: audio, duration: 1)
        let captions = scene.sources.appendingPathComponent("Tide.vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:00.800\nThe slip is clear.\n".utf8).write(to: captions)

        scene.model.importAndOpenFiles(urls: [captions, audio])
        drainImports(of: scene.model)

        XCTAssertFalse(scene.model.showError, "the transcript was refused as a book: \(scene.model.errorMessage ?? "-")")
        let books = scene.model.library.books
        XCTAssertEqual(books.map(\.title), ["Tide"], "the transcript file was imported as a book of its own, or the audio was not")
        let book = try XCTUnwrap(books.first)
        XCTAssertTrue(TranscriptStore.hasTranscript(of: book), "the audio's import did not attach the transcript")

        // Alone, the same file is still refused, with the way to attach it.
        scene.model.importAndOpenFiles(urls: [captions])
        drainImports(of: scene.model)
        XCTAssertTrue(scene.model.showError)
        XCTAssertEqual(scene.model.library.books.count, 1)
    }

    // MARK: - Questions of Every Kind

    /// A duplicate, a new book, and a ZIP archive of two books are imported
    /// together while "After Importing a Book" asks each time. The questions
    /// are asked one at a time in the order they arose; keeping the duplicate
    /// asks next about its own original, before the others; each title says
    /// where the question stands; and every answer acts on its own file.
    func testQuestionsOfEveryKindAreAskedInOrderAndActOnTheirOwnFiles() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try writeSource("Bestiary of Knots", in: scene)
        let shelf = try writeArchive("Chart Shelf", titles: ["Charts of Shoals", "Dredging Logs"], in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.askEachTime)

        scene.model.importFiles(urls: [atlas.copy, bestiary, shelf], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(waitingQuestions(of: scene.model), [
            "duplicate: Atlas of Tides",
            "original: Bestiary of Knots.txt",
            "original: Chart Shelf.zip",
            "folder: Chart Shelf.zip",
        ])
        XCTAssertEqual(scene.model.currentImportDecisionWording?.title, "Duplicate Book Found, 1 of 4")

        scene.model.answerCurrentImportDecision(.keepBoth)
        XCTAssertEqual(waitingQuestions(of: scene.model).first, "original: Atlas of Tides.txt")
        XCTAssertEqual(scene.model.currentImportDecisionWording?.title, "Delete Original File Permanently? 2 of 5")
        scene.model.answerCurrentImportDecision(.deleteOriginal)
        XCTAssertEqual(scene.model.currentImportDecisionWording?.title, "Delete Original File Permanently? 3 of 5")
        scene.model.answerCurrentImportDecision(.cancel)
        XCTAssertEqual(scene.model.currentImportDecisionWording?.title, "Delete Original File Permanently? 4 of 5")
        scene.model.answerCurrentImportDecision(.deleteOriginal)
        XCTAssertEqual(scene.model.currentImportDecisionWording?.title, "Create Folder for Imported Books? 5 of 5")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.createFolder(named: "Charts")).succeeded)

        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        XCTAssertEqual(scene.model.importDecisions.position, 1, "the count did not start again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: atlas.copy.path), "the kept copy's original was not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bestiary.path), "Keep did not keep its own file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelf.path), "the archive was not deleted")
        let charts = BookFolder(name: "Charts", parentPath: scene.folder.path).fullPath
        XCTAssertEqual(titles(in: charts, of: scene.model), ["Charts of Shoals", "Dredging Logs"])
        XCTAssertEqual(
            titles(in: scene.folder.path, of: scene.model),
            [atlas.existing.title, "Atlas of Tides", "Bestiary of Knots"]
        )
        XCTAssertEqual(scene.opened.ids, [], "a book opened that no import asked to open")
    }

    // MARK: - Cancelling

    /// Cancelling a question settles that question alone: the duplicate's
    /// new copy is discarded, its original stays though the preference says
    /// to delete it, and the next question is asked.
    func testCancellingAQuestionSettlesOnlyThatQuestion() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing, bestiary.existing])
        useAfterImportingBehavior(.deleteAfterImport)

        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let cancelled = try XCTUnwrap(scene.model.importDecisions.current?.duplicate)

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)

        XCTAssertEqual(waitingQuestions(of: scene.model), ["duplicate: Bestiary of Knots"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cancelled.book.tmbDirectory.path),
            "the cancelled copy's package is left"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.copy.path), "cancelling deleted the original")
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id, bestiary.existing.id])
    }

    /// The import overlay's Cancel withdraws every question of the batch it
    /// stops: the duplicate's new copy is discarded, every original is kept,
    /// the ZIP archive's books stay where they are, and no book opens,
    /// though the imports asked to open theirs.
    func testTheOverlaysCancelWithdrawsTheBatchsQuestions() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try writeSource("Bestiary of Knots", in: scene)
        let shelf = try writeArchive("Chart Shelf", titles: ["Charts of Shoals", "Dredging Logs"], in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.askEachTime)

        scene.model.importSingleFileAsync(from: atlas.copy, toFolder: scene.folder.path, openAfterImport: true)
        scene.model.importSingleFileAsync(from: bestiary, toFolder: scene.folder.path, openAfterImport: true)
        scene.model.importFiles(urls: [shelf], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        XCTAssertEqual(scene.model.importDecisions.waiting.count, 4)
        let discarded = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)

        let cancel = try XCTUnwrap(LibraryWindowView.importProgressOverlay(for: scene.model).onCancel)
        cancel()

        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: discarded.tmbDirectory.path),
            "the duplicate's new copy was left on disk"
        )
        for original in [atlas.copy, bestiary, shelf] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), original.lastPathComponent)
        }
        XCTAssertEqual(
            titles(in: scene.folder.path, of: scene.model),
            [atlas.existing.title, "Bestiary of Knots", "Charts of Shoals", "Dredging Logs"]
        )
        XCTAssertEqual(try scene.folder.entries(), Set(scene.model.library.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(scene.opened.ids, [], "a book of the cancelled batch opened")
    }

    /// An import of the stopped batch that was still waiting when the
    /// overlay's Cancel was pressed, and that runs to its end because single
    /// files are not stopped, never asks its question: its duplicate is
    /// discarded at once.
    func testAQuestionTheStoppedBatchRaisesLaterIsNeverAsked() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        // The queue is held while the import waits and the batch is
        // cancelled.
        let gate = DispatchSemaphore(value: 0)
        scene.model.importOperationQueue.enqueue { gate.wait() }
        scene.model.importSingleFileAsync(from: atlas.copy, toFolder: scene.folder.path)

        scene.model.cancelImports()
        gate.signal()
        drainImports(of: scene.model)

        XCTAssertTrue(scene.model.importDecisions.isEmpty, "the stopped batch's question was asked")
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
        XCTAssertEqual(
            try scene.folder.entries(), [atlas.existing.tmbDirectoryName],
            "the stopped batch's duplicate was left on disk"
        )
    }

    /// Imports queued after the Cancel are a batch of their own, which the
    /// Cancel never reaches: their questions are asked.
    func testImportsQueuedAfterTheCancelStillAsk() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)

        scene.model.cancelImports()
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(waitingQuestions(of: scene.model), ["duplicate: Atlas of Tides"])
    }

    // MARK: - Opening After Import

    /// A book opened from Finder opens once its own question is answered,
    /// whatever questions come between: here another file's duplicate and
    /// that file's original are asked first, and answering them opens
    /// nothing.
    func testABookOpensOnceItsOwnQuestionIsAnsweredWhateverComesBetween() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try writeSource("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.askEachTime)

        scene.model.importSingleFileAsync(from: atlas.copy, toFolder: scene.folder.path)
        scene.model.importSingleFileAsync(from: bestiary, toFolder: scene.folder.path, openAfterImport: true)
        drainImports(of: scene.model)
        let opened = try XCTUnwrap(scene.model.library.books.first { $0.title == "Bestiary of Knots" })
        XCTAssertEqual(
            waitingQuestions(of: scene.model),
            ["duplicate: Atlas of Tides", "original: Bestiary of Knots.txt"]
        )

        scene.model.answerCurrentImportDecision(.keepBoth)
        XCTAssertEqual(
            waitingQuestions(of: scene.model),
            ["original: Atlas of Tides.txt", "original: Bestiary of Knots.txt"]
        )
        scene.model.answerCurrentImportDecision(.cancel)
        XCTAssertEqual(scene.opened.ids, [], "a book opened for a question about another file")
        scene.model.answerCurrentImportDecision(.cancel)

        XCTAssertEqual(scene.opened.ids, [opened.id])
    }

    /// A duplicate whose new copy is discarded opens nothing, though its
    /// import asked to open it.
    func testADiscardedDuplicateOpensNothing() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importSingleFileAsync(from: atlas.copy, toFolder: scene.folder.path, openAfterImport: true)
        drainImports(of: scene.model)
        scene.model.answerCurrentImportDecision(.cancel)

        XCTAssertEqual(scene.opened.ids, [])
    }

    /// A book taken out of the library while its question waited is not
    /// opened once the question is answered.
    func testABookRemovedWhileItsQuestionWaitedIsNotOpened() throws {
        let scene = try makeScene()
        let bestiary = try writeSource("Bestiary of Knots", in: scene)
        useAfterImportingBehavior(.askEachTime)

        scene.model.importSingleFileAsync(from: bestiary, toFolder: scene.folder.path, openAfterImport: true)
        drainImports(of: scene.model)
        let book = try XCTUnwrap(scene.model.library.books.first)
        scene.model.library.removeBook(id: book.id)
        scene.model.answerCurrentImportDecision(.cancel)

        XCTAssertEqual(scene.opened.ids, [])
    }

    // MARK: - Answers

    /// An answer reaches only its own question: one meant for a question
    /// already settled, as a second press of its button gives, does
    /// nothing, so it can never answer the question after it, and an answer
    /// a question does not take does nothing either.
    func testAnAnswerReachesOnlyItsOwnQuestion() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing, bestiary.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let first = try XCTUnwrap(scene.model.importDecisions.current)
        scene.model.answerImportDecision(first.id, with: .keepBoth)
        let second = try XCTUnwrap(scene.model.importDecisions.current)

        XCTAssertTrue(scene.model.answerImportDecision(first.id, with: .replaceExisting).succeeded)
        XCTAssertTrue(scene.model.answerImportDecision(second.id, with: .deleteOriginal).succeeded)
        XCTAssertTrue(scene.model.answerImportDecision(second.id, with: .createFolder(named: "Shelf")).succeeded)

        XCTAssertEqual(scene.model.importDecisions.current?.id, second.id)
        XCTAssertTrue(scene.model.library.books.contains { $0.id == bestiary.existing.id })
        XCTAssertTrue(scene.model.library.folders.isEmpty)
    }

    /// A Replace that cannot remove the library's copy changes nothing,
    /// keeps the question asked, and says why; the question can still be
    /// answered otherwise.
    func testAReplaceThatFailsKeepsAskingAndSaysWhy() throws {
        let scene = try makeScene()
        let source = try writeSource("Atlas of Tides", in: scene)
        let imported = try FileImportService.importFileWithReport(from: source, toFolder: scene.folder.path)
        // A listed copy with no managed package, which deletion refuses.
        let unmanaged = Book(
            title: "Unmanaged Atlas",
            format: .txt,
            filePath: "/nonexistent/Unmanaged Atlas.txt",
            md5Hash: imported.book.md5Hash
        )
        scene.model.library = Library(books: [unmanaged])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.completeSingleImportedBook(imported, originalURL: source)

        let outcome = scene.model.answerCurrentImportDecision(.replaceExisting)

        let message = try XCTUnwrap(outcome.failureMessage)
        XCTAssertTrue(message.hasPrefix("Could not replace duplicate: "), message)
        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, imported.book.id)
        XCTAssertEqual(scene.model.library.books.map(\.id), [unmanaged.id])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [unmanaged.id, imported.book.id])
    }

    /// A folder name the library refuses keeps the ZIP archive's question
    /// asked and says why; another name then moves the books.
    func testARefusedFolderNameKeepsAskingAndSaysWhy() throws {
        let scene = try makeScene()
        let shelf = try writeArchive("Chart Shelf", titles: ["Charts of Shoals", "Dredging Logs"], in: scene)
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [shelf], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        let refused = scene.model.answerCurrentImportDecision(.createFolder(named: "Charts.tmb"))

        XCTAssertEqual(refused.failureMessage, "Could not create folder: \(FolderOperationConflict.invalidName.message)")
        XCTAssertNotNil(scene.model.importDecisions.current?.zipBatch)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.createFolder(named: "Charts")).succeeded)
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        let charts = BookFolder(name: "Charts", parentPath: scene.folder.path).fullPath
        XCTAssertEqual(titles(in: charts, of: scene.model), ["Charts of Shoals", "Dredging Logs"])
    }

    /// Two copies of one book, each replacing the library's copy, leave one
    /// copy: the second question names, and its Replace removes, the copy the
    /// first Replace put in place, which is the one matching when it is
    /// answered.
    func testReplaceActsOnTheCopyMatchingWhenAnswered() throws {
        let scene = try makeScene()
        var atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        atlas.existing.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "Coil")]
        let again = scene.sources.appendingPathComponent("Atlas of Tides Again.txt")
        try FileManager.default.copyItem(at: atlas.copy, to: again)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy, again], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        scene.model.answerCurrentImportDecision(.replaceExisting)
        let message = try XCTUnwrap(scene.model.currentImportDecisionWording?.message)
        XCTAssertTrue(message.hasPrefix("“Atlas of Tides Again.txt” matches “Atlas of Tides”, "), message)
        scene.model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(scene.model.library.books.map(\.title), ["Atlas of Tides Again"])
        XCTAssertEqual(try scene.folder.entries(), Set(scene.model.library.books.map(\.tmbDirectoryName)))
        // The second question, queued for the same book, replaced the first
        // copy in turn: the book keeps its ID and its bookmark through both.
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
        XCTAssertEqual(scene.model.library.books.first?.bookmarks.map(\.label), ["Coil"])
    }

    /// While the library moves, no question of any kind is answered: each
    /// answer is refused, saying why, changes nothing, and leaves its
    /// question asked. A Library window that showed a question as the move
    /// began keeps showing it, since a window shows one sheet at a time, so
    /// its buttons can still be pressed. Once the move ends, every question
    /// is answered as usual.
    func testNoQuestionIsAnsweredWhileTheLibraryMoves() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let shelf = try writeArchive("Chart Shelf", titles: ["Charts of Shoals", "Dredging Logs"], in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.askEachTime)
        scene.model.importFiles(urls: [atlas.copy, shelf], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let books = scene.model.library.books.map(\.id)
        let packages = try scene.folder.entries()

        // A duplicate: neither copy is touched.
        let duplicateAnswers = whileTheLibraryMoves(scene.model) {
            [ImportDecisionAnswer.keepBoth, .replaceExisting, .cancel].map { answer in
                scene.model.answerCurrentImportDecision(answer)
            }
        }
        XCTAssertEqual(duplicateAnswers, Array(repeating: Self.moveRefusal, count: 3))
        XCTAssertEqual(waitingQuestions(of: scene.model).first, "duplicate: Atlas of Tides")
        XCTAssertEqual(scene.model.library.books.map(\.id), books)
        XCTAssertEqual(try scene.folder.entries(), packages, "an answer changed the library's folder")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)

        // An original file: it stays where it is.
        XCTAssertEqual(waitingQuestions(of: scene.model).first, "original: Atlas of Tides.txt")
        let deletion = whileTheLibraryMoves(scene.model) { scene.model.answerCurrentImportDecision(.deleteOriginal) }
        XCTAssertEqual(deletion, Self.moveRefusal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.copy.path), "the original was deleted during the move")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded, "the archive's own original")

        // A ZIP archive's books: no folder is made, and the books stay put.
        XCTAssertEqual(waitingQuestions(of: scene.model), ["folder: Chart Shelf.zip"])
        let folder = whileTheLibraryMoves(scene.model) {
            scene.model.answerCurrentImportDecision(.createFolder(named: "Charts"))
        }
        XCTAssertEqual(folder, Self.moveRefusal)
        XCTAssertTrue(scene.model.library.folders.isEmpty, "a folder was made during the move")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.createFolder(named: "Charts")).succeeded)

        let charts = BookFolder(name: "Charts", parentPath: scene.folder.path).fullPath
        XCTAssertEqual(titles(in: charts, of: scene.model), ["Charts of Shoals", "Dredging Logs"])
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    // MARK: - The Window That Asks

    /// Every import path records the Library window it started in, so that
    /// window asks its questions: Open Book... and New from Text....
    func testImportsRecordTheWindowTheyStartedIn() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let notes = "Coil the line clockwise, and hang it where it can dry."
        let existingText = try FileImportService.importText(
            notes, title: "Deck Notes", author: "", fileName: "Deck Notes.txt", toFolder: scene.folder.path
        ).book
        scene.model.library = Library(books: [atlas.existing, existingText])
        useAfterImportingBehavior(.keepOriginal)
        let window = ImportOrigin(windowNumber: 4242)

        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path, from: window)
        scene.model.createBookFromText(
            title: "Deck Notes", author: "", text: notes, toFolder: scene.folder.path, from: window
        )
        drainImports(of: scene.model)

        XCTAssertEqual(scene.model.importDecisions.waiting.map(\.request.origin), [window, window])
    }

    // MARK: - The Reading List (FR09)

    /// Replace gives the new copy the replaced book's place on the reading
    /// list: the copy takes the book's ID (ST04), which the list names where
    /// the book was, the others keep their order, and the list saved in the
    /// index says the same. Keep Both leaves the list as it was.
    func testReplaceGivesTheCopyTheReplacedBooksPlaceOnTheReadingList() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        let charts = try FileImportService.importFileWithReport(
            from: writeSource("Chart Notes", in: scene),
            toFolder: scene.folder.path
        ).book
        let listed = [bestiary.existing.id, atlas.existing.id, charts.id]
        scene.model.library = Library(
            books: [atlas.existing, bestiary.existing, charts],
            readingList: ReadingList(bookIDs: listed)
        )
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        LibraryPersistenceService.flushPendingSave()

        let copy = try XCTUnwrap(scene.model.library.books.first { $0.title == "Atlas of Tides" })
        XCTAssertEqual(copy.id, atlas.existing.id, "the copy kept an ID of its own instead of the replaced book's (ST04)")
        XCTAssertEqual(scene.model.library.readingList.bookIDs, listed)
        XCTAssertEqual(scene.model.readingListBooks.map(\.title), [bestiary.existing.title, "Atlas of Tides", charts.title])
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(saved.readingList.bookIDs, listed)
    }

    // MARK: - Replace Existing Keeps the Old Copy's State (ST04)

    /// The file a book came from changes, as a new edition saved over it
    /// does, and is imported again elsewhere. Replace Existing puts the new
    /// copy in the book's place, as that same book: its ID, its folder, its
    /// place in the library's order and on the reading list, its settings,
    /// and its bookmark, which follows its words into the new text. The old
    /// package is gone, the new one is in the book's folder, and its record
    /// names the book by its own ID.
    func testReplaceKeepsTheOldCopysIDFolderPlacesAndSettings() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let source = scene.sources.appendingPathComponent("Atlas of Tides.txt")
        try Data(Self.firstEdition.utf8).write(to: source)
        var existing = try FileImportService.importFileWithReport(from: source, toFolder: shelf.path).book
        let firstText = try MarkdownCacheService.loadFromCache(for: existing)
        let firstChapter = try XCTUnwrap(firstText.chapters.first?.text) as NSString
        let marked = TextPlace(chapter: 0, offset: firstChapter.range(of: Self.markedWords).location)
        existing.bookmarks = [Bookmark(
            number: 1,
            chapterIndex: 0,
            characterOffset: marked.offset,
            label: "Pilot",
            anchor: firstText.anchor(at: marked, measuredIn: nil)
        )]
        existing.localWPM = 240
        existing.localEndOfBookBehavior = EndOfBookBehavior.loop.rawValue
        existing.manualSortOrder = 2
        let other = try FileImportService.importFileWithReport(from: writeSource("Bestiary of Knots", in: scene), toFolder: shelf.path).book
        scene.model.library = Library(books: [existing, other], readingList: ReadingList(bookIDs: [other.id, existing.id]))
        useAfterImportingBehavior(.keepOriginal)

        try Data(Self.secondEdition.utf8).write(to: source)
        scene.model.importFiles(urls: [source], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        XCTAssertEqual(scene.model.library.books.map(\.id), [existing.id, other.id])
        let replaced = try XCTUnwrap(scene.model.bookByID(existing.id))
        XCTAssertEqual(replaced.tmbDirectoryName, copy.tmbDirectoryName)
        XCTAssertEqual(replaced.md5Hash, copy.md5Hash)
        XCTAssertEqual(replaced.folderPath, shelf.path)
        XCTAssertEqual(replaced.manualSortOrder, 2)
        XCTAssertEqual(replaced.localWPM, 240)
        XCTAssertEqual(replaced.localEndOfBookBehavior, EndOfBookBehavior.loop.rawValue)
        XCTAssertEqual(scene.model.library.readingList.bookIDs, [other.id, existing.id])
        XCTAssertEqual(try shelf.entries(), [other.tmbDirectoryName, copy.tmbDirectoryName])
        XCTAssertEqual(try scene.folder.entries(), [], "the new copy's package stayed where it was imported")
        let secondText = try MarkdownCacheService.loadFromCache(for: replaced)
        let secondChapter = try XCTUnwrap(secondText.chapters.first?.text) as NSString
        XCTAssertEqual(replaced.bookmarks.map(\.characterOffset), [secondChapter.range(of: Self.markedWords).location])
        XCTAssertEqual(replaced.bookmarks.map(\.label), ["Pilot"])
        XCTAssertEqual(try BookInfo.load(from: replaced.tmbDirectory).metadata.bookID, existing.id)
    }

    /// While the library's copy is open in a reader, which would go on
    /// saving its places in the old text into the book, Replace Existing
    /// waits: it says why, changes nothing, and keeps the question asked.
    /// Once the reader closes, the same answer replaces the book.
    func testReplaceWaitsWhileTheOldCopyIsOpenInAReader() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let asked = try XCTUnwrap(scene.model.importDecisions.current)
        let copy = try XCTUnwrap(asked.duplicate?.book)
        scene.model.openBookIDs = [atlas.existing.id]

        let refused = scene.model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(
            refused.failureMessage,
            "“Earlier Atlas of Tides” is open in a reader. Close it, then choose Replace Existing again."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.id, asked.id)
        XCTAssertEqual(scene.model.library.books.map(\.tmbDirectoryName), [atlas.existing.tmbDirectoryName])
        XCTAssertEqual(try scene.folder.entries(), [atlas.existing.tmbDirectoryName, copy.tmbDirectoryName])

        scene.model.openBookIDs = []
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
        XCTAssertEqual(try scene.folder.entries(), [copy.tmbDirectoryName])
    }

    /// While the library's copy is being transcribed, or its audio edited,
    /// Replace Existing waits too, saying why, and the question stays.
    func testReplaceWaitsWhileTheOldCopyIsTranscribedOrItsAudioEdited() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let asked = try XCTUnwrap(scene.model.importDecisions.current)

        TranscribedBooks.shared.setTranscribing(atlas.existing.id)
        let whileTranscribed = scene.model.answerCurrentImportDecision(.replaceExisting)
        TranscribedBooks.shared.setTranscribing(nil)
        scene.model.audioEditActivity.beginUse(of: atlas.existing.id)
        let whileEdited = scene.model.answerCurrentImportDecision(.replaceExisting)
        scene.model.audioEditActivity.endUse(of: atlas.existing.id)

        XCTAssertEqual(
            whileTranscribed.failureMessage,
            "“Earlier Atlas of Tides” is being transcribed, and replacing it now would lose the transcript. "
                + "Wait until the transcription ends, or cancel it, then choose Replace Existing again."
        )
        XCTAssertEqual(
            whileEdited.failureMessage,
            "The audio of “Earlier Atlas of Tides” is being edited. Close the audio editor, or wait until it has saved, "
                + "then choose Replace Existing again."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.id, asked.id)
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
    }

    /// While the library's copy is being exported, or a folder edit moves
    /// books between folders, Replace Existing waits too, saying why, and
    /// changes nothing; once both are over, the same answer replaces the
    /// book (ST04 review, finding 5).
    func testReplaceWaitsWhileTheOldCopyIsExportedOrBooksMoveBetweenFolders() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let asked = try XCTUnwrap(scene.model.importDecisions.current)

        BookExportModel.noteExportStarted([atlas.existing.id])
        let whileExported = scene.model.answerCurrentImportDecision(.replaceExisting)
        BookExportModel.noteExportEnded([atlas.existing.id])
        let hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        let whileMoving = scene.model.answerCurrentImportDecision(.replaceExisting)
        hold.release()

        XCTAssertEqual(
            whileExported.failureMessage,
            "“Earlier Atlas of Tides” is being exported, and replacing it now would stop the export. "
                + "Wait until the export ends, then choose Replace Existing again."
        )
        XCTAssertEqual(
            whileMoving.failureMessage,
            "TextMouth is moving books between folders. Wait until that finishes, then choose Replace Existing again."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.id, asked.id)
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
    }

    /// While the library's copy is being read again in another encoding
    /// (encodingchoice), which writes into the package a replacement
    /// removes, Replace Existing waits in the re-read's own words, changes
    /// nothing, and keeps the question asked; once the re-read is over, the
    /// same answer replaces the book.
    func testReplaceWaitsWhileTheOldCopyIsReadAgainInAnotherEncoding() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let asked = try XCTUnwrap(scene.model.importDecisions.current)
        let copy = try XCTUnwrap(asked.duplicate?.book)

        // As the re-read marks its book, from the confirmation until its row has the new reading.
        scene.model.booksBeingReadAgain.insert(atlas.existing.id)
        let whileReadAgain = scene.model.answerCurrentImportDecision(.replaceExisting)
        scene.model.booksBeingReadAgain.remove(atlas.existing.id)

        XCTAssertEqual(
            whileReadAgain.failureMessage,
            "TextMouth is reading “Earlier Atlas of Tides” again in another encoding. Try again when that finishes."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.id, asked.id)
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
        XCTAssertEqual(try scene.folder.entries(), [atlas.existing.tmbDirectoryName, copy.tmbDirectoryName])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
    }

    /// A session editing the old copy's text with Edit Text ends with the
    /// replacement, through the editor, which says so aloud: what the
    /// session watched went with the old copy, and a check of the new copy's
    /// files against it would take them for an edit.
    func testReplaceEndsTheOldCopysEditTextSessionSayingSo() throws {
        let scene = try makeScene()
        let sessions = BookTextEditSessions()
        let editor = BookTextEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Replace Edit Text"),
            notificationCenter: NotificationCenter(),
            explain: { _, _ in true },
            chooseApp: { _, _ in nil },
            open: { _, _ in },
            isAppActive: { true }
        )
        scene.model.textEditSessions = sessions
        scene.model.bookTextEditor = { editor }
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        let baseline = BookTextBaseline(source: nil, cache: TranscriptFixtures.fingerprint())
        sessions.begin(atlas.existing.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        }

        XCTAssertFalse(sessions.isEditing(atlas.existing.id), "the old copy's Edit Text session goes on")
        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Edit Text has stopped for Earlier Atlas of Tides, since a new copy replaced it. "
                + "Choose Edit Text again to edit the new copy's text.",
        ])
    }

    /// The new copy is committed before the old copy's package goes: its
    /// record carries the book's state under the book's ID, and the saved
    /// index names it, as a crash right after the commit would find them. So
    /// an old package that then cannot be removed changes nothing of the
    /// replacement: it stays in its folder, and the library's alert says so.
    func testAnOldCopyThatCannotBeRemovedStaysBehindItsCommittedReplacement() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let copySource = try writeSource("Atlas of Tides", in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier Atlas of Tides.txt")
        try FileManager.default.copyItem(at: copySource, to: earlier)
        var existing = try FileImportService.importFileWithReport(from: earlier, toFolder: shelf.path).book
        existing.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "Coil")]
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        let refusal = CocoaError(.fileWriteNoPermission)
        scene.model.removesReplacedPackage = { _, _ in throw refusal }
        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)

        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        let replaced = try XCTUnwrap(scene.model.bookByID(existing.id))
        XCTAssertEqual(replaced.tmbDirectoryName, copy.tmbDirectoryName)
        XCTAssertEqual(try shelf.entries(), [existing.tmbDirectoryName, copy.tmbDirectoryName])
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(saved.books.first { $0.id == existing.id }?.tmbDirectoryName, copy.tmbDirectoryName)
        let record = try BookInfo.load(from: replaced.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, existing.id)
        XCTAssertEqual(record.bookmarks.map(\.label), ["Coil"])
        // A launch after a stop here reads that index, and leaves the old
        // package, whose record names the listed book, unadopted.
        var relaunched = saved
        XCTAssertEqual(FileImportService.adoptOrphanedTMBPackages(library: &relaunched, libraryDirectory: shelf.url), 0)
        XCTAssertEqual(relaunched.books.filter { $0.id == existing.id }.map(\.tmbDirectoryName), [copy.tmbDirectoryName])
        XCTAssertEqual(
            scene.model.errorMessage,
            "The new copy took the place of “Earlier Atlas of Tides”, but the old copy's files could not be deleted, "
                + "so they stay in its folder: \(refusal.localizedDescription)"
        )
    }

    /// With the Trash off, an old package holding a read-only folder, as an
    /// imported RTFD's can be, which a plain deletion stops partway through,
    /// is set aside and deleted whole: nothing of it stays in its folder,
    /// under any name, and the edit kept beside the new copy's text is never
    /// taken back out of the new package.
    func testAnOldPackageHoldingAReadOnlyFolderGoesWholeAndTheNewCopyKeepsTheEdit() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let copySource = try writeSource("Atlas of Tides", in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier Atlas of Tides.txt")
        try FileManager.default.copyItem(at: copySource, to: earlier)
        var existing = try FileImportService.importFileWithReport(from: earlier, toFolder: shelf.path).book
        let edited = Data("An edit the reader made to the chart notes.".utf8)
        try edited.write(to: MarkdownCacheService.cacheURL(for: existing))
        existing.editedText = EditedText(cacheDigest: FingerprintHasher.md5.digestOfData(edited), takenAt: Date())
        let locked = existing.tmbDirectory.appendingPathComponent("Plates.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("plate".utf8).write(to: locked.appendingPathComponent("plate.txt"))
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        }

        XCTAssertNil(scene.model.errorMessage)
        XCTAssertEqual(try shelf.entries(), [copy.tmbDirectoryName], "something of the old package stayed in its folder")
        let replaced = try XCTUnwrap(scene.model.bookByID(existing.id))
        let names = try FileManager.default.contentsOfDirectory(atPath: replaced.tmbDirectory.path)
        let kept = try XCTUnwrap(names.first(where: TextMouthPaths.isKeptTextCopy), "the edit kept beside the new text is gone")
        XCTAssertEqual(try Data(contentsOf: replaced.tmbDirectory.appendingPathComponent(kept)), edited)
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Replaced “Earlier Atlas of Tides”. Its earlier text was kept as \(kept), in the book's package."]
        )
    }

    /// A replacement whose index cannot be saved, as while an unreadable
    /// index holds every write, changes nothing: the library and both
    /// packages are as they were, the new copy's record names its own ID
    /// again, and the question stays, saying why.
    func testAReplacementWhoseIndexCannotBeSavedChangesNothing() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let copySource = try writeSource("Atlas of Tides", in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier Atlas of Tides.txt")
        try FileManager.default.copyItem(at: copySource, to: earlier)
        let existing = try FileImportService.importFileWithReport(from: earlier, toFolder: shelf.path).book
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        let published = try FileManager.default.contentsOfDirectory(atPath: copy.tmbDirectory.path).sorted()
        try scene.index.stage(.truncated, at: scene.index.indexURL)
        _ = LibraryPersistenceService.load()

        let outcome = scene.model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(
            outcome.failureMessage,
            "Could not replace duplicate: TextMouth couldn't save the library's index, so it left both copies as they are."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, copy.id)
        XCTAssertEqual(scene.model.library.books, [existing])
        XCTAssertEqual(try scene.folder.entries(), [copy.tmbDirectoryName])
        XCTAssertEqual(try shelf.entries(), [existing.tmbDirectoryName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.tmbDirectory.path).sorted(), published)
        XCTAssertEqual(try BookInfo.load(from: copy.tmbDirectory).metadata.bookID, copy.id)
    }

    /// An audiobook whose copy has the same audio, imported under another
    /// name, keeps its transcript, which the library then lists it with,
    /// and the import offers no transcription of it.
    func testReplacingAnAudiobookKeepsItsTranscriptAndOffersNone() throws {
        let scene = try makeScene()
        let earlier = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: earlier, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: earlier, toFolder: scene.folder.path).book
        let transcript = try TranscriptFixtures.transcript(of: existing, sentences: [
            "Earlier Tide.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        try TranscriptStore.write(transcript, into: existing.tmbDirectory)
        let copySource = scene.sources.appendingPathComponent("Tide.wav")
        try FileManager.default.copyItem(at: earlier, to: copySource)
        scene.model.library = Library(books: [existing])
        scene.model.offersTranscription = { _ in true }
        useAfterImportingBehavior(.keepOriginal)
        let bookID = existing.id
        addTeardownBlock { await MainActor.run { TranscribedBooks.shared.record(bookID, isTranscribed: false) } }

        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)

        let replaced = try XCTUnwrap(scene.model.bookByID(existing.id))
        XCTAssertTrue(scene.model.importDecisions.isEmpty, "a transcription was offered: \(waitingQuestions(of: scene.model))")
        XCTAssertTrue(TranscribedBooks.shared.contains(existing.id))
        guard case .found(let kept) = TranscriptStore.read(from: replaced.tmbDirectory) else {
            return XCTFail("the transcript stayed behind")
        }
        XCTAssertEqual(kept.files.map(\.path), [replaced.bookFileURL.lastPathComponent])
    }

    /// A book imported at the Reading List goes to the folder the window
    /// showed last and joins the end of the list, and VoiceOver hears that
    /// it joined the list and where the book itself is. A book imported
    /// anywhere else leaves the list alone and says nothing of it.
    func testABookImportedAtTheReadingListJoinsItsEnd() throws {
        let scene = try makeScene()
        let charts = try FileImportService.importFileWithReport(
            from: writeSource("Chart Notes", in: scene),
            toFolder: scene.folder.path
        ).book
        scene.model.library = Library(books: [charts], readingList: ReadingList(bookIDs: [charts.id]))
        useAfterImportingBehavior(.keepOriginal)
        let atlas = try writeSource("Atlas of Tides", in: scene)
        let bestiary = try writeSource("Bestiary of Knots", in: scene)

        let recorder = recordingAnnouncements {
            scene.model.importFiles(urls: [atlas], toFolder: scene.folder.path, addingToReadingList: true)
            drainImports(of: scene.model)
            scene.model.importFiles(urls: [bestiary], toFolder: scene.folder.path)
            drainImports(of: scene.model)
        }

        let imported = try XCTUnwrap(scene.model.library.books.first { $0.title == "Atlas of Tides" })
        XCTAssertEqual(imported.folderPath, scene.folder.path)
        XCTAssertTrue(scene.model.library.books.contains { $0.title == "Bestiary of Knots" })
        XCTAssertEqual(scene.model.readingListBooks.map(\.title), [charts.title, "Atlas of Tides"])
        XCTAssertEqual(
            Self.readingListAnnouncements(recorder),
            ["Added to reading list: Atlas of Tides. The book is in \(scene.folder.path)."]
        )
    }

    /// A ZIP archive's books imported at the Reading List join it in the
    /// order they reach the library, said together; the archive's own
    /// question is still asked.
    func testAnArchiveImportedAtTheReadingListJoinsItInOrder() throws {
        let scene = try makeScene()
        useAfterImportingBehavior(.keepOriginal)
        let archive = try writeArchive("Logbooks", titles: ["Atlas of Tides", "Bestiary of Knots"], in: scene)

        let recorder = recordingAnnouncements {
            scene.model.importFiles(urls: [archive], toFolder: scene.folder.path, addingToReadingList: true)
            drainImports(of: scene.model)
        }

        XCTAssertEqual(scene.model.library.books.count, 2)
        XCTAssertEqual(scene.model.readingList.bookIDs, scene.model.library.books.map(\.id))
        XCTAssertEqual(
            Self.readingListAnnouncements(recorder),
            ["Added 2 books to the reading list. The books are in \(scene.folder.path)."]
        )
        XCTAssertEqual(waitingQuestions(of: scene.model), ["folder: Logbooks.zip"])
    }

    /// A duplicate imported at the Reading List joins it only once it is
    /// kept, as Keep Both keeps it; Replace gives the copy the old copy's
    /// place instead, and adds nothing more.
    func testADuplicateImportedAtTheReadingListJoinsItOnceKept() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(
            books: [atlas.existing, bestiary.existing],
            readingList: ReadingList(bookIDs: [bestiary.existing.id])
        )
        useAfterImportingBehavior(.keepOriginal)

        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path, addingToReadingList: true)
        drainImports(of: scene.model)
        XCTAssertEqual(scene.model.readingList.bookIDs, [bestiary.existing.id], "a copy joined before it was kept")

        let recorder = recordingAnnouncements {
            scene.model.answerCurrentImportDecision(.keepBoth)
            scene.model.answerCurrentImportDecision(.replaceExisting)
        }

        let atlasCopy = try XCTUnwrap(scene.model.library.books.first { $0.title == "Atlas of Tides" })
        let bestiaryCopy = try XCTUnwrap(scene.model.library.books.first { $0.title == "Bestiary of Knots" })
        XCTAssertEqual(scene.model.readingList.bookIDs, [bestiaryCopy.id, atlasCopy.id])
        XCTAssertEqual(
            Self.readingListAnnouncements(recorder),
            ["Added to reading list: Atlas of Tides. The book is in \(scene.folder.path)."]
        )
    }

    /// New from Text at the Reading List makes a book in the folder the
    /// window showed last, which joins the end of the list and says so.
    func testNewFromTextAtTheReadingListJoinsIt() throws {
        let scene = try makeScene()

        let recorder = recordingAnnouncements {
            scene.model.createBookFromText(
                title: "Deck Notes",
                author: "",
                text: "Coil the line and dry it before stowing.",
                toFolder: scene.folder.path,
                addingToReadingList: true
            )
            drainImports(of: scene.model)
        }

        let book = try XCTUnwrap(scene.model.library.books.first)
        XCTAssertEqual(book.folderPath, scene.folder.path)
        XCTAssertEqual(scene.model.readingList.bookIDs, [book.id])
        XCTAssertEqual(
            Self.readingListAnnouncements(recorder),
            ["Added to reading list: Deck Notes. The book is in \(scene.folder.path)."]
        )
    }

    /// The announcements `recorder` heard of the reading list.
    private static func readingListAnnouncements(_ recorder: AnnouncementRecorder) -> [String] {
        recorder.announcements.map(\.message).filter { $0.contains("reading list") }
    }

    // MARK: - A Question a Quit Leaves Unanswered

    /// While its question waits, a duplicate's new copy, already in its
    /// library folder, holds the marker that says so; Keep Both and Replace
    /// Existing each take it off the package they keep, and a question still
    /// waiting keeps its own.
    func testAWaitingCopyIsMarkedUntilAnAnswerKeepsIt() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        let bestiary = try existingBookAndCopy("Bestiary of Knots", in: scene)
        scene.model.library = Library(books: [atlas.existing, bestiary.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy, bestiary.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        let copies = scene.model.importDecisions.waiting.compactMap { $0.duplicate?.book }
        XCTAssertEqual(copies.map(\.title), ["Atlas of Tides", "Bestiary of Knots"])
        for copy in copies {
            XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "\(copy.title)'s copy is not marked as waiting")
        }
        let atlasCopy = try XCTUnwrap(copies.first)
        let bestiaryCopy = try XCTUnwrap(copies.last)

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        XCTAssertTrue(scene.model.library.books.contains { $0.id == atlasCopy.id })
        XCTAssertFalse(DuplicateQuestionMarker.isHeld(by: atlasCopy.tmbDirectory), "Keep Both left the marker")
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: bestiaryCopy.tmbDirectory), "the copy still asked about lost its marker")

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)
        let replaced = try XCTUnwrap(scene.model.bookByID(bestiary.existing.id))
        XCTAssertEqual(replaced.tmbDirectoryName, bestiaryCopy.tmbDirectoryName)
        XCTAssertFalse(DuplicateQuestionMarker.isHeld(by: replaced.tmbDirectory), "Replace Existing left the marker")
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    /// A replacement the library cannot commit, as while an unreadable
    /// index holds every write, takes the new copy's marker off on its way
    /// and puts it back: the question stays, and so does the marker of the
    /// copy it asks about, moved back from the old copy's folder.
    func testAReplacementThatIsNotCommittedLeavesTheCopyMarked() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let copySource = try writeSource("Atlas of Tides", in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier Atlas of Tides.txt")
        try FileManager.default.copyItem(at: copySource, to: earlier)
        let existing = try FileImportService.importFileWithReport(from: earlier, toFolder: shelf.path).book
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        try scene.index.stage(.truncated, at: scene.index.indexURL)
        _ = LibraryPersistenceService.load()

        XCTAssertFalse(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)

        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, copy.id)
        XCTAssertEqual(try scene.folder.entries(), [copy.tmbDirectoryName])
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "the copy whose question stays lost its marker")
    }

    /// Replace Existing moves the new copy into the folder of the copy it
    /// replaces, which here is another folder: the marker comes off the
    /// package where it lands, the one the library then lists.
    func testAReplacementInAnotherFolderUnmarksTheCopyWhereItLands() throws {
        let scene = try makeScene()
        let shelf = makeIntegrationLibraryFolder("Import Decisions Shelf")
        let copySource = try writeSource("Atlas of Tides", in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier Atlas of Tides.txt")
        try FileManager.default.copyItem(at: copySource, to: earlier)
        let existing = try FileImportService.importFileWithReport(from: earlier, toFolder: shelf.path).book
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [copySource], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "the waiting copy is not marked")

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.replaceExisting).succeeded)

        let replaced = try XCTUnwrap(scene.model.bookByID(existing.id))
        XCTAssertEqual(replaced.folderPath, shelf.path)
        XCTAssertEqual(try shelf.entries(), [copy.tmbDirectoryName])
        XCTAssertFalse(DuplicateQuestionMarker.isHeld(by: replaced.tmbDirectory), "the copy kept its marker where it landed")
    }

    /// TextMouth quits while a duplicate's question waits, and the question
    /// stands a day or more. The next launch, a library model of its own on
    /// the same data directory, reads the index as it was and runs its
    /// repair: the copy no one answered for goes to the Trash, whatever the
    /// Trash setting (here it is off, the data review's scenario: no one
    /// chose to delete the copy, which may be all that is left of the new
    /// content), the library lists only the book it matched, the debug log
    /// says what went and why, an alert names the book, and the file the
    /// copy came from stays. Once that book is deleted, the next launch
    /// brings back nothing.
    func testALaunchAfterAQuitMovesTheCopyWhoseQuestionWasNeverAnsweredToTheTrash() throws {
        let scene = try makeScene()
        XCTAssertFalse(ConfigService.shared.config.moveToTrashInsteadOfDeleting, "the Trash setting is on")
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        let trash = try TrashStandIn(in: makeSandboxDirectory("Unanswered Trash"))

        let relaunched = LibraryViewModel(initializeServices: false)
        relaunched.library = Library(books: [atlas.existing])
        XCTAssertEqual(
            relaunched.adoptOrphanedPackages(
                libraryDirectory: scene.folder.url, trashItem: trash.move, now: Date().addingTimeInterval(2 * 86_400)
            ),
            0
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.tmbDirectory.path), "the copy no one answered for stays")
        XCTAssertEqual(trash.moved, [copy.tmbDirectory.lastPathComponent], "the copy did not reach the Trash")
        XCTAssertTrue(relaunched.showError, "nothing told the listener")
        XCTAssertEqual(relaunched.errorTitle, "Duplicate Copies Moved to the Trash")
        XCTAssertEqual(
            relaunched.errorMessage,
            "TextMouth moved the new copy of “Atlas of Tides” to the Trash, because the question "
                + "whether to keep it as a duplicate was never answered before TextMouth closed. "
                + "To get it back, open the Trash and choose Put Back."
        )
        XCTAssertEqual(relaunched.library.books.map(\.id), [atlas.existing.id])
        let lines = debugLogLines(naming: copy.tmbDirectory).filter { $0.contains("DUPLICATE_UNANSWERED") }
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(
            lines.first?.hasSuffix(
                ": DUPLICATE_UNANSWERED: \(DiagnosticLog.loggablePath(copy.tmbDirectory)): "
                    + "the duplicate question about this new copy was never answered, so the copy was moved to the Trash"
            ) == true,
            "\(lines)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.copy.path), "the file the copy came from is gone")

        relaunched.library.removeBook(id: atlas.existing.id)
        try FileImportService.deleteBookPackage(atlas.existing)
        XCTAssertEqual(relaunched.adoptOrphanedPackages(libraryDirectory: scene.folder.url, trashItem: trash.move), 0)
        XCTAssertEqual(relaunched.library.books, [])
        XCTAssertEqual(try scene.folder.entries(), [])
    }

    /// A copy whose question is less than a day old is left alone by the
    /// launch, unadopted and still marked, since another Mac sharing the
    /// library may be asking that question and still hold its answer; the
    /// debug log says why, and nothing is shown. The same launch a day
    /// later moves it to the Trash (data review, finding 3).
    func testALaunchLeavesTheCopyWhoseQuestionIsLessThanADayOld() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        let trash = try TrashStandIn(in: makeSandboxDirectory("Fresh Question Trash"))

        let relaunched = LibraryViewModel(initializeServices: false)
        relaunched.library = Library(books: [atlas.existing])
        let almostADay = Date().addingTimeInterval(23 * 3_600)
        XCTAssertEqual(
            relaunched.adoptOrphanedPackages(libraryDirectory: scene.folder.url, trashItem: trash.move, now: almostADay),
            0
        )

        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "a question under a day old lost its copy")
        XCTAssertEqual(trash.moved, [])
        XCTAssertFalse(relaunched.showError, "something was shown for a copy that stayed")
        let lines = debugLogLines(naming: copy.tmbDirectory).filter { $0.contains("DUPLICATE_UNANSWERED") }
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(
            lines.first?.hasSuffix("but it is less than a day old, so another Mac may be asking it and the copy stays") == true,
            "\(lines)"
        )

        relaunched.adoptOrphanedPackages(
            libraryDirectory: scene.folder.url, trashItem: trash.move, now: Date().addingTimeInterval(25 * 3_600)
        )
        XCTAssertEqual(trash.moved, [copy.tmbDirectory.lastPathComponent], "a day later the copy stayed")
    }

    /// The repair run by the library still asking a duplicate's question, as
    /// when it runs again once the data directory comes back, keeps that
    /// question's copy, unadopted and still marked, and logs nothing about
    /// it; the question is then answered as usual.
    func testTheRepairOfTheLibraryStillAskingKeepsItsWaitingCopy() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)

        XCTAssertEqual(scene.model.adoptOrphanedPackages(libraryDirectory: scene.folder.url), 0)

        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "the copy whose question waits was discarded")
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id])
        XCTAssertEqual(debugLogLines(naming: copy.tmbDirectory).filter { $0.contains("DUPLICATE_UNANSWERED") }, [])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [atlas.existing.id, copy.id])
        XCTAssertFalse(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory))
    }

    /// A walk of the library that discards nothing, as a rebuild of the
    /// data directory runs while a question waits, never adopts that
    /// question's copy, even one matched only by the file it came from,
    /// whose content differs, which the library would otherwise take as a
    /// second book: a Keep Both no one chose. The copy stays for its answer.
    func testNoWalkAdoptsACopyWhoseQuestionWaits() throws {
        let scene = try makeScene()
        let source = try writeSource("Atlas of Tides", in: scene)
        let existing = try FileImportService.importFileWithReport(from: source, toFolder: scene.folder.path).book
        try Data("Notes kept for Atlas of Tides, revised: coil the line sunwise.".utf8).write(to: source)
        scene.model.library = Library(books: [existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [source], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        XCTAssertNotEqual(copy.md5Hash, existing.md5Hash)

        var walked = Library(books: [existing])
        XCTAssertEqual(FileImportService.adoptOrphanedTMBPackages(library: &walked, libraryDirectory: scene.folder.url), 0)

        XCTAssertEqual(walked.books.map(\.id), [existing.id])
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "a walk that discards nothing took the copy")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.keepBoth).succeeded)
        XCTAssertEqual(scene.model.library.books.map(\.id), [existing.id, copy.id])
    }

    /// A copy whose package is gone while its question waits, as another
    /// Mac's launch or Finder can take it, is never kept: Keep Both and
    /// Replace Existing each keep the question and say why, the library is
    /// as it was, and the file the copy came from stays, though "After
    /// Importing a Book" deletes the original of a book kept. Cancel then
    /// settles the question.
    func testACopyWhosePackageIsGoneIsNeverKept() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.deleteAfterImport)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        try FileManager.default.removeItem(at: copy.tmbDirectory)
        let gone = "The files of the new copy of “Atlas of Tides” are no longer in the library, so it can't be kept. "
            + "Choose Cancel, then import the file again."

        XCTAssertEqual(scene.model.answerCurrentImportDecision(.keepBoth).failureMessage, gone)
        XCTAssertEqual(scene.model.answerCurrentImportDecision(.replaceExisting).failureMessage, gone)

        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, copy.id)
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.copy.path), "the original of a copy never kept is gone")
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.copy.path))
    }

    /// While the library can't be reached (its drive dropped off while the
    /// question waited) the new copy is intact, though it cannot be found
    /// there: Keep Both and Replace Existing keep the question and say the
    /// library can't be reached and to answer once it is back, naming the
    /// book, and not that the copy's files are gone, which would send the
    /// listener to Cancel an intact copy (data review, finding 6).
    func testWhileTheLibraryCannotBeReachedTheQuestionStaysAndSaysSo() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        // The drive drops off: the copy cannot be found where it was.
        scene.model.noteDataDirectoryUnavailable(.driveNotConnected(volume: "Spare Disk", folder: "/Volumes/Spare Disk/TextMouth"))
        let unreachable = "The library can't be reached right now, so TextMouth can't keep the new copy of “Atlas of Tides”. "
            + "Answer again once the library is back."

        XCTAssertEqual(scene.model.answerCurrentImportDecision(.keepBoth).failureMessage, unreachable)
        XCTAssertEqual(scene.model.answerCurrentImportDecision(.replaceExisting).failureMessage, unreachable)

        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, copy.id, "the question did not stay")
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: copy.tmbDirectory), "the copy was touched")
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
    }

    /// A marker that won't come off keeps the copy out and the question
    /// asked, and the sentence names the book, says TextMouth could not keep
    /// the copy, and that Cancel discards it, without the hidden file's name
    /// the system's reason holds (data review, finding 6). Cancel then
    /// discards the copy.
    func testAMarkerThatWontComeOffSaysTheCopyCouldNotBeKept() throws {
        let scene = try makeScene()
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
        scene.model.library = Library(books: [atlas.existing])
        useAfterImportingBehavior(.keepOriginal)
        scene.model.importFiles(urls: [atlas.copy], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        let copy = try XCTUnwrap(scene.model.importDecisions.current?.duplicate?.book)
        // A package that can't be written to keeps its marker from coming off.
        let package = copy.tmbDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        let outcome = scene.model.answerCurrentImportDecision(.keepBoth)

        XCTAssertEqual(
            outcome.failureMessage,
            "TextMouth could not keep the new copy of “Atlas of Tides”. "
                + "Choose Cancel to discard the copy, then import the file again."
        )
        XCTAssertEqual(scene.model.importDecisions.current?.duplicate?.book.id, copy.id, "the question did not stay")
        XCTAssertEqual(scene.model.library.books, [atlas.existing])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path), "Cancel left the copy")
    }

    // MARK: - Fixtures

    /// The words a bookmark marks in both editions of a book.
    private static let markedWords = "the harbor pilot"

    /// A book's text as it was first imported.
    private static let firstEdition = """
        The first paragraph tells of the tides along the outer coast.

        The second paragraph names the harbor pilot who keeps the channel.

        The last paragraph ends the chart notes for the season.
        """

    /// The same book's next edition, saved over the first: a preface comes
    /// before the first edition's words, which move on.
    private static let secondEdition = """
        A preface added in this edition, before the notes begin.

        The first paragraph tells of the tides along the outer coast.

        The second paragraph names the harbor pilot who keeps the channel.

        The last paragraph ends the chart notes for the season.
        """

    /// A stand-in for the Trash: moves each item into a folder of the
    /// test's own, as the Trash takes one, and records the names it took,
    /// so nothing a test discards reaches the real Trash.
    private final class TrashStandIn {
        /// The folder the Trash's items land in.
        private let folder: URL
        /// The names of the items moved, in order.
        private(set) var moved: [String] = []

        init(in folder: URL) {
            self.folder = folder
        }

        /// Moves `item` into the folder, as `FileManager.trashItem` moves it
        /// to the Trash.
        func move(_ item: URL) throws {
            try FileManager.default.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            moved.append(item.lastPathComponent)
        }
    }

    /// What one test imports from and into.
    private struct Scene {
        /// The library folder the test imports into, removed when it ends.
        let folder: IntegrationLibraryFolder
        /// Where the test's source files are written, outside the library.
        let sources: URL
        /// The library model under test: inert, so only the imports under
        /// test can ask anything, and starting with no books.
        let model: LibraryViewModel
        /// The books the model opened, in place of reader windows.
        let opened: OpenedBooks
        /// The library index as the test found it, put back when it ends.
        let index: LibraryIndexSandbox
    }

    /// A scene of this test's own. The library index is put back, and
    /// deletions are kept out of the Trash, until the test ends.
    private func makeScene() throws -> Scene {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        return Scene(
            folder: makeIntegrationLibraryFolder("Import Decisions"),
            sources: try makeSandboxDirectory("ImportDecisionSources"),
            model: model,
            opened: OpenedBooks(recordingFor: model),
            index: sandbox
        )
    }

    /// A plain-text book file named `title`, outside the library, whose
    /// words are its own.
    private func writeSource(_ title: String, in scene: Scene) throws -> URL {
        let url = scene.sources.appendingPathComponent("\(title).txt")
        try Data("Notes kept for \(title): coil the line and dry it before stowing.".utf8).write(to: url)
        return url
    }

    /// A book already in the scene's folder, titled "Earlier" and `title`,
    /// and a second file with the same words, named `title`, which imports
    /// as its duplicate.
    private func existingBookAndCopy(_ title: String, in scene: Scene) throws -> (existing: Book, copy: URL) {
        let copy = try writeSource(title, in: scene)
        let earlier = scene.sources.appendingPathComponent("Earlier \(title).txt")
        try FileManager.default.copyItem(at: copy, to: earlier)
        let existing = try FileImportService.importFileWithReport(from: earlier, toFolder: scene.folder.path).book
        return (existing, copy)
    }

    /// A ZIP archive named `name`, outside the library, holding one
    /// plain-text book for each of `titles`.
    private func writeArchive(_ name: String, titles: [String], in scene: Scene) throws -> URL {
        let entries = titles.map { title in
            TestZIPEntry("\(title).txt", Data("Notes kept for \(title): stow the chart dry.".utf8))
        }
        let made = try makeTemporaryZip(prefix: "ImportDecisions", orderedEntries: entries)
        let archive = scene.sources.appendingPathComponent("\(name).zip")
        try FileManager.default.moveItem(at: made, to: archive)
        return archive
    }

    /// Waits until every import `model` has queued so far has run, then
    /// until the main queue has run the work those imports sent it.
    private func drainImports(of model: LibraryViewModel) {
        let imported = expectation(description: "the import queue ran everything queued before")
        model.importOperationQueue.enqueue { imported.fulfill() }
        wait(for: [imported], timeout: 60)
        let mainQueue = expectation(description: "the main queue ran what the imports sent it")
        DispatchQueue.main.async { mainQueue.fulfill() }
        wait(for: [mainQueue], timeout: 10)
    }

    /// The questions `model` is waiting to ask, in order, each named by its
    /// kind and what it is about: the new copy's title, the original file's
    /// name, or the archive's name.
    private func waitingQuestions(of model: LibraryViewModel) -> [String] {
        model.importDecisions.waiting.map { decision in
            switch decision.kind {
            case .duplicate(let duplicate):
                return "duplicate: \(duplicate.book.title)"
            case .originalFile(let original):
                return "original: \(original.url.lastPathComponent)"
            case .zipFolder(let batch):
                return "folder: \(batch.archiveURL.lastPathComponent)"
            case .transcriptionOffer(let offer):
                return "transcribe: \(offer.bookTitle)"
            }
        }
    }

    /// The titles of `model`'s books in the library folder `path`.
    private func titles(in path: String, of model: LibraryViewModel) -> Set<String> {
        Set(model.library.books.filter { $0.folderPath == path }.map(\.title))
    }

    /// What every answer gets while the library moves.
    private static let moveRefusal = OperationOutcome.failure(DataDirectoryMoveWording.importAnswerRefusal)

    /// Runs `body` while `model` has a data-directory move under way, as the
    /// move sets one for as long as it runs, and returns what `body`
    /// returns. Nothing is copied: only the answers are under test.
    private func whileTheLibraryMoves<Value>(_ model: LibraryViewModel, _ body: () -> Value) -> Value {
        model.dataDirectoryMove = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Spare Disk/TextMouth"))
        defer { model.dataDirectoryMove = nil }
        return body()
    }
}
