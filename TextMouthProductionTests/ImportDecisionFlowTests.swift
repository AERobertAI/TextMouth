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
        let atlas = try existingBookAndCopy("Atlas of Tides", in: scene)
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

    /// Replace gives the new copy, which has an ID of its own, the replaced
    /// book's place on the reading list: the list names the copy where the
    /// book was, the others keep their order, and the list saved in the
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
        XCTAssertNotEqual(copy.id, atlas.existing.id)
        XCTAssertEqual(scene.model.library.readingList.bookIDs, [bestiary.existing.id, copy.id, charts.id])
        XCTAssertEqual(scene.model.readingListBooks.map(\.title), [bestiary.existing.title, "Atlas of Tides", charts.title])
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(saved.readingList.bookIDs, [bestiary.existing.id, copy.id, charts.id])
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

    // MARK: - Fixtures

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
            opened: OpenedBooks(recordingFor: model)
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
