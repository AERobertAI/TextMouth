import XCTest
@testable import TextMouth

/// The queue of import questions and their words (TODO I01): questions are
/// asked one at a time in the order they arose, a question an answer raises
/// is asked next, the run of questions is counted for the sheet's title,
/// the window an import started in asks its questions, and each question
/// names what it is about.
final class ImportDecisionQueueTests: XCTestCase {

    // MARK: - The Queue

    /// The queue asks its questions in the order they arose and counts the
    /// questions asked since it was last empty, those settled included.
    func testTheQueueAsksInOrderAndCountsTheRun() {
        var queue = ImportDecisionQueue()
        let questions = ["First", "Second", "Third", "Fourth"].map(Self.zipQuestion)
        for question in questions.prefix(3) {
            queue.enqueue(question)
        }

        XCTAssertEqual(queue.current?.id, questions[0].id)
        XCTAssertEqual([queue.position, queue.total], [1, 3])
        XCTAssertEqual(queue.settleCurrent()?.id, questions[0].id)
        XCTAssertEqual(queue.current?.id, questions[1].id)
        XCTAssertEqual([queue.position, queue.total], [2, 3])
        queue.enqueue(questions[3])
        XCTAssertEqual([queue.position, queue.total], [2, 4])
        XCTAssertEqual(queue.waiting.map(\.id), questions.dropFirst().map(\.id))
    }

    /// A question an answer raises is asked next, before the others, and the
    /// count goes on: following the last question too.
    func testAFollowUpIsAskedNextAndCounted() {
        var queue = ImportDecisionQueue()
        let first = Self.zipQuestion("First")
        let second = Self.zipQuestion("Second")
        let followUp = Self.zipQuestion("Follow-Up")
        let lastFollowUp = Self.zipQuestion("Last Follow-Up")
        queue.enqueue(first)
        queue.enqueue(second)

        queue.settleCurrent(followedBy: followUp)

        XCTAssertEqual(queue.waiting.map(\.id), [followUp.id, second.id])
        XCTAssertEqual([queue.position, queue.total], [2, 3])
        queue.settleCurrent()
        queue.settleCurrent(followedBy: lastFollowUp)
        XCTAssertEqual(queue.waiting.map(\.id), [lastFollowUp.id])
        XCTAssertEqual([queue.position, queue.total], [4, 4])
    }

    /// Withdrawing takes the chosen questions, the one being asked included,
    /// keeps the rest in order, and does not count the withdrawn as settled;
    /// once the queue is empty the count starts again.
    func testWithdrawingKeepsTheRestInOrder() {
        var queue = ImportDecisionQueue()
        let questions = ["First", "Second", "Third", "Fourth"].map(Self.zipQuestion)
        questions.forEach { queue.enqueue($0) }
        queue.settleCurrent()
        let withdrawnIDs: Set = [questions[1].id, questions[3].id]

        let withdrawn = queue.withdrawAll { withdrawnIDs.contains($0.id) }

        XCTAssertEqual(withdrawn.map(\.id), [questions[1].id, questions[3].id])
        XCTAssertEqual(queue.waiting.map(\.id), [questions[2].id])
        XCTAssertEqual([queue.position, queue.total], [2, 2])
        XCTAssertEqual(queue.withdrawAll { _ in true }.map(\.id), [questions[2].id])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual([queue.position, queue.total], [1, 0])
        XCTAssertNil(queue.settleCurrent())
    }

    /// The window an import started in asks its questions while it is open;
    /// otherwise the first open Library window does, so a question whose
    /// window closed is still asked, and with none open it waits.
    func testTheWindowAnImportStartedInAsksItsQuestions() {
        let first = ImportOrigin(windowNumber: 11)
        let second = ImportOrigin(windowNumber: 22)
        let closed = ImportOrigin(windowNumber: 33)

        XCTAssertEqual(ImportDecisionQueue.askingWindow(for: second, among: [first, second]), second)
        XCTAssertEqual(ImportDecisionQueue.askingWindow(for: closed, among: [first, second]), first)
        XCTAssertEqual(ImportDecisionQueue.askingWindow(for: nil, among: [second, first]), second)
        XCTAssertNil(ImportDecisionQueue.askingWindow(for: first, among: []))
    }

    /// Each answer fits the questions it can answer, and Cancel fits every
    /// question.
    func testEachAnswerFitsItsOwnKindOfQuestion() {
        let duplicate = Self.duplicateQuestion().kind
        let original = Self.originalFileQuestion().kind
        let batch = Self.zipQuestion("Shelf").kind
        let fits: [(ImportDecisionAnswer, [Bool])] = [
            (.replaceExisting, [true, false, false]),
            (.keepBoth, [true, false, false]),
            (.deleteOriginal, [false, true, false]),
            (.createFolder(named: "Shelf"), [false, false, true]),
            (.cancel, [true, true, true]),
        ]
        for (answer, expected) in fits {
            XCTAssertEqual([duplicate, original, batch].map(answer.fits), expected, "\(answer)")
        }
    }

    // MARK: - Wording

    /// A title counts the questions asked since none was waiting, as in
    /// "Duplicate Book Found, 1 of 3"; a title ending in a question mark
    /// pauses there instead of at a comma; a lone question is not counted.
    func testTitlesSayWhereTheQuestionStands() {
        XCTAssertEqual(
            ImportDecisionWording.counted("Duplicate Book Found", position: 1, total: 3),
            "Duplicate Book Found, 1 of 3"
        )
        XCTAssertEqual(
            ImportDecisionWording.counted("Move Original File to Trash?", position: 2, total: 3),
            "Move Original File to Trash? 2 of 3"
        )
        XCTAssertEqual(ImportDecisionWording.counted("Duplicate Book Found", position: 1, total: 1), "Duplicate Book Found")
    }

    /// Each kind of question names what it is about: a duplicate the file it
    /// came from and the book it matches, with what an incomplete copy
    /// lacks; an original file its name and where it would go; a ZIP
    /// archive its name and how many books it added. VoiceOver hears the
    /// title, then the question.
    func testEachQuestionNamesWhatItIsAbout() {
        let existing = Book(title: "Earlier Atlas", format: .txt, filePath: "/library/a.txt", md5Hash: "atlas")
        let copy = Book(
            title: "Atlas of Tides", format: .txt, filePath: "/library/b.txt", md5Hash: "atlas",
            sourceFilePath: "/Downloads/Atlas of Tides.txt"
        )
        let duplicate = ImportDecision(
            kind: .duplicate(.init(book: copy, existing: existing, originalURL: nil, warning: "1 of 3 chapters could not be read.")),
            request: ImportRequest()
        )
        let duplicateWording = ImportDecisionWording(for: duplicate, position: 2, total: 3, movesToTrash: true)
        XCTAssertEqual(duplicateWording.title, "Duplicate Book Found, 2 of 3")
        XCTAssertEqual(
            duplicateWording.message,
            "“Atlas of Tides.txt” matches “Earlier Atlas”, which is already in your library. "
                + "Replace the existing copy (updates the .tmb and timestamp) or keep both as separate entries?"
                + "\n\nThe copy just imported is incomplete. 1 of 3 chapters could not be read."
        )
        XCTAssertEqual(duplicateWording.announcement, "Duplicate Book Found, 2 of 3. " + duplicateWording.message)
        XCTAssertNil(duplicateWording.originalFile)
        XCTAssertTrue(
            ImportDecisionWording(for: duplicate, position: 1, total: 1, matchingTitle: "Atlas, Second Edition", movesToTrash: true)
                .message.hasPrefix("“Atlas of Tides.txt” matches “Atlas, Second Edition”, "),
            "a duplicate names the copy it matches now"
        )

        let deletion = OriginalFileDeletionWording(movesToTrash: false, fileName: "Notes.epub")
        let originalWording = ImportDecisionWording(for: Self.originalFileQuestion(), position: 1, total: 1, movesToTrash: false)
        XCTAssertEqual(originalWording.title, "Delete Original File Permanently?")
        XCTAssertEqual(originalWording.message, deletion.confirmationMessage)
        XCTAssertEqual(originalWording.originalFile, deletion)
        XCTAssertEqual(originalWording.announcement, "Delete Original File Permanently? " + deletion.confirmationMessage)

        let batch = ImportDecision(
            kind: .zipFolder(.init(
                archiveURL: URL(fileURLWithPath: "/Downloads/Chart Shelf.zip"),
                books: [existing, copy],
                folderPath: ""
            )),
            request: ImportRequest()
        )
        let batchWording = ImportDecisionWording(for: batch, position: 3, total: 3, movesToTrash: true)
        XCTAssertEqual(batchWording.title, "Create Folder for Imported Books? 3 of 3")
        XCTAssertEqual(
            batchWording.message,
            "2 books were imported from “Chart Shelf.zip”. Would you like to create a new folder to hold them?"
        )
    }

    // MARK: - Fixtures

    /// A question about a ZIP archive named `name`, with no books.
    private static func zipQuestion(_ name: String) -> ImportDecision {
        let batch = ImportDecision.ZipBatch(
            archiveURL: URL(fileURLWithPath: "/Downloads/\(name).zip"),
            books: [],
            folderPath: ""
        )
        return ImportDecision(kind: .zipFolder(batch), request: ImportRequest())
    }

    /// A duplicate's question about books that exist only in memory.
    private static func duplicateQuestion() -> ImportDecision {
        let existing = Book(title: "Earlier Atlas", format: .txt, filePath: "/library/a.txt", md5Hash: "atlas")
        let copy = Book(title: "Atlas of Tides", format: .txt, filePath: "/library/b.txt", md5Hash: "atlas")
        return ImportDecision(
            kind: .duplicate(.init(book: copy, existing: existing, originalURL: nil, warning: nil)),
            request: ImportRequest()
        )
    }

    /// A question about the original file "Notes.epub".
    private static func originalFileQuestion() -> ImportDecision {
        ImportDecision(
            kind: .originalFile(.init(url: URL(fileURLWithPath: "/Downloads/Notes.epub"), bookID: nil)),
            request: ImportRequest()
        )
    }
}
