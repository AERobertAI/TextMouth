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

    /// Mapping the waiting questions' books, as a data-directory move does
    /// (TODO S04), passes every book a question holds through the transform
    /// (a duplicate's new copy and the copy it matched, a ZIP archive's
    /// books) and keeps each question itself, the order, and the count.
    func testMappingBooksKeepsEachQuestionAndChangesOnlyItsBooks() throws {
        var queue = ImportDecisionQueue()
        let duplicate = Self.duplicateQuestion()
        let original = Self.originalFileQuestion()
        let book = Book(title: "Harbor Atlas", format: .txt, filePath: "/library/c.txt", md5Hash: "harbor")
        let zip = ImportDecision(
            kind: .zipFolder(.init(archiveURL: URL(fileURLWithPath: "/Downloads/Charts.zip"), books: [book], folderPath: "Charts")),
            request: ImportRequest()
        )
        [duplicate, original, zip].forEach { queue.enqueue($0) }
        queue.settleCurrent(followedBy: duplicate)

        queue.mapBooks { book in
            var moved = book
            moved.filePath = "/moved" + book.filePath
            return moved
        }

        XCTAssertEqual(queue.waiting.map(\.id), [duplicate.id, original.id, zip.id])
        XCTAssertEqual([queue.position, queue.total], [2, 4])
        XCTAssertEqual(queue.current?.duplicate?.book.filePath, "/moved/library/b.txt")
        XCTAssertEqual(queue.current?.duplicate?.existing.filePath, "/moved/library/a.txt")
        // The ZIP question is the third waiting; a short queue fails here, not in a trap.
        let zipWaiting = try XCTUnwrap(queue.waiting[safe: 2], "the queue has no third waiting question")
        guard case .zipFolder(let batch) = zipWaiting.kind else {
            return XCTFail("The ZIP question changed kind")
        }
        XCTAssertEqual(batch.books.map(\.filePath), ["/moved/library/c.txt"])
        XCTAssertEqual(batch.books.map(\.id), [book.id])
        XCTAssertEqual(batch.folderPath, "Charts")
    }

    /// One answer is carried out off the main actor at a time: the queue
    /// marks the question being answered, refuses to mark a second until the
    /// first ends, and settles and withdraws nothing by marking.
    func testOneAnswerAtATimeIsCarriedOutOffTheMainActor() {
        var queue = ImportDecisionQueue()
        let first = Self.zipQuestion("First")
        let second = Self.zipQuestion("Second")
        queue.enqueue(first)
        queue.enqueue(second)
        XCTAssertNil(queue.answering)

        XCTAssertTrue(queue.beginAnswering(first.id))
        XCTAssertEqual(queue.answering, first.id)
        XCTAssertFalse(queue.beginAnswering(second.id), "a second answer does not begin while the first is carried out")
        XCTAssertEqual(queue.answering, first.id)

        queue.endAnswering()
        XCTAssertNil(queue.answering)
        XCTAssertTrue(queue.beginAnswering(second.id))
        XCTAssertEqual(queue.waiting.map(\.id), [first.id, second.id], "answering settles and withdraws nothing")
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
                + "Replace the existing copy, or keep both as separate books?"
                + "\n\n" + Self.textKeptWords + " " + Self.trashWords
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

    /// With "Move to Trash instead of deleting" off, the duplicate question
    /// says what Replace Existing keeps of the old copy of a text book, and
    /// what it does not, and that the old copy is deleted for good (ST04).
    /// The wording is pinned exactly, as VoiceOver reads it.
    func testTheDuplicateQuestionSaysWhatReplacingKeepsAndThatTheOldCopyIsDeleted() {
        let wording = ImportDecisionWording(for: Self.duplicateQuestion(), position: 1, total: 1, movesToTrash: false)
        XCTAssertEqual(
            wording.message,
            "“Atlas of Tides” matches “Earlier Atlas”, which is already in your library. "
                + "Replace the existing copy, or keep both as separate books?"
                + "\n\n" + Self.textKeptWords + " " + Self.deletedWords
        )
        XCTAssertEqual(ImportDecisionWording.replacingKeepsTextSentence, Self.textKeptWords)
        XCTAssertEqual(ImportDecisionWording.replacedCopySentence(movesToTrash: false), Self.deletedWords)
        XCTAssertEqual(ImportDecisionWording.replacedCopySentence(movesToTrash: true), Self.trashWords)
    }

    /// An audiobook's duplicate question says its transcript is kept only
    /// for the same audio, and that its audio edits are not kept (ST04).
    func testAnAudiobooksDuplicateQuestionSaysWhatReplacingKeeps() {
        let existing = Book(title: "Earlier Tide", format: .audio, filePath: "/library/a.m4b", md5Hash: "tide")
        let copy = Book(title: "Tide", format: .audio, filePath: "/library/b.m4b", md5Hash: "tide")
        let question = ImportDecision(
            kind: .duplicate(.init(book: copy, existing: existing, originalURL: nil, warning: nil)),
            request: ImportRequest()
        )

        XCTAssertEqual(
            ImportDecisionWording(for: question, position: 1, total: 1, movesToTrash: true).message,
            "“Tide” matches “Earlier Tide”, which is already in your library. "
                + "Replace the existing copy, or keep both as separate books?"
                + "\n\n" + Self.audioKeptWords + " " + Self.trashWords
        )
        XCTAssertEqual(ImportDecisionWording.replacingKeepsAudioSentence, Self.audioKeptWords)
    }

    /// When the new copy of an audiobook brought a transcript from a file
    /// beside its audio (FMT23), the question says exactly which transcript
    /// replacing keeps (B1): the existing copy's, recognized or touched by
    /// the listener, rather than the file's; or the file's, in place of an
    /// untouched transcript from outside. With nothing to choose, it says
    /// what it always said.
    func testAnAudiobooksDuplicateQuestionSaysWhichTranscriptReplacingKeeps() {
        let existing = Book(title: "Earlier Tide", format: .audio, filePath: "/library/a.m4b", md5Hash: "tide")
        let copy = Book(title: "Tide", format: .audio, filePath: "/library/b.m4b", md5Hash: "tide")
        func message(_ outcome: DuplicateReplacement.TranscriptOutcome) -> String {
            let duplicate = ImportDecision.DuplicateBook(
                book: copy, existing: existing, originalURL: nil, warning: nil, transcriptOutcome: outcome
            )
            let question = ImportDecision(kind: .duplicate(duplicate), request: ImportRequest())
            return ImportDecisionWording(for: question, position: 1, total: 1, movesToTrash: true).message
        }
        let choice = "“Tide” matches “Earlier Tide”, which is already in your library. "
            + "Replace the existing copy, or keep both as separate books?\n\n"
        let keepsExisting = "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, "
            + "and place on the reading list, and its transcript when the audio is the same, rather than "
            + "the transcript file found beside the new copy's audio. Edits of its audio or of its manifest are not kept."
        let broughtReplaces = "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, "
            + "and place on the reading list. The transcript file found beside the new copy's audio replaces "
            + "the existing copy's transcript. Edits of its audio or of its manifest are not kept."

        XCTAssertEqual(message(.asBefore), choice + Self.audioKeptWords + " " + Self.trashWords)
        XCTAssertEqual(message(.keepsExisting), choice + keepsExisting + " " + Self.trashWords)
        XCTAssertEqual(message(.broughtReplacesExisting), choice + broughtReplaces + " " + Self.trashWords)
        // A text book's question has no transcript to choose.
        XCTAssertEqual(
            ImportDecisionWording.replacingKeepsSentence(existing: .epub, new: .epub, transcript: .keepsExisting),
            Self.textKeptWords
        )
    }

    /// When one copy is an audiobook and the other is not, the question
    /// says replacing keeps only the book's place in the library, and not
    /// its position, bookmarks with their notes, or settings, whichever copy
    /// is which; the copy matching now decides, over the one matched on
    /// import (ST04 review, finding 1). Its words are true of a DAISY
    /// talking book, which they never call "not an audiobook" (ST04 verify,
    /// finding 2).
    func testADuplicateOfTheOtherKindSaysReplacingKeepsOnlyItsPlace() {
        let text = Book(title: "Earlier Tide", format: .daisy, filePath: "/library/a.zip", md5Hash: "text")
        let audio = Book(title: "Tide", format: .audio, filePath: "/library/b.zip", md5Hash: "audio")
        let audioForText = ImportDecision(
            kind: .duplicate(.init(book: audio, existing: text, originalURL: nil, warning: nil)),
            request: ImportRequest()
        )
        let textForAudio = ImportDecision(
            kind: .duplicate(.init(book: text, existing: audio, originalURL: nil, warning: nil)),
            request: ImportRequest()
        )
        let acrossKinds = "One copy is played from its recording and the other is read aloud from its text, "
            + "so replacing keeps only the existing copy's folder and place on the reading list, "
            + "not its reading position, its bookmarks and their notes, or its settings."

        for question in [audioForText, textForAudio] {
            XCTAssertTrue(
                ImportDecisionWording(for: question, position: 1, total: 1, movesToTrash: false).message
                    .hasSuffix("\n\n" + acrossKinds + " " + Self.deletedWords)
            )
        }
        XCTAssertTrue(
            ImportDecisionWording(for: audioForText, position: 1, total: 1, matchingFormat: .audio, movesToTrash: false).message
                .hasSuffix("\n\n" + Self.audioKeptWords + " " + Self.deletedWords),
            "the copy matching now is an audiobook too"
        )
        XCTAssertEqual(ImportDecisionWording.replacingAcrossKindsSentence, acrossKinds)
    }

    /// An incomplete copy's warning comes last, after the choice and what
    /// replacing keeps, whichever way the old copy goes.
    func testTheDuplicateQuestionPutsTheWarningAfterTheChoiceAndWhatIsKept() {
        let existing = Book(title: "Earlier Atlas", format: .txt, filePath: "/library/a.txt", md5Hash: "atlas")
        let copy = Book(title: "Atlas of Tides", format: .txt, filePath: "/library/b.txt", md5Hash: "atlas")
        let question = ImportDecision(
            kind: .duplicate(.init(book: copy, existing: existing, originalURL: nil, warning: "2 of 9 chapters could not be read.")),
            request: ImportRequest()
        )
        XCTAssertEqual(
            ImportDecisionWording(for: question, position: 1, total: 1, movesToTrash: false).message,
            "“Atlas of Tides” matches “Earlier Atlas”, which is already in your library. "
                + "Replace the existing copy, or keep both as separate books?"
                + "\n\n" + Self.textKeptWords + " " + Self.deletedWords
                + "\n\nThe copy just imported is incomplete. 2 of 9 chapters could not be read."
        )
        XCTAssertEqual(
            ImportDecisionWording(for: question, position: 1, total: 1, movesToTrash: true).message,
            "“Atlas of Tides” matches “Earlier Atlas”, which is already in your library. "
                + "Replace the existing copy, or keep both as separate books?"
                + "\n\n" + Self.textKeptWords + " " + Self.trashWords
                + "\n\nThe copy just imported is incomplete. 2 of 9 chapters could not be read."
        )
    }

    /// The Replace Existing button's hint says what the new copy keeps of
    /// the old one (ST04).
    func testTheReplaceExistingHintSaysWhatTheNewCopyKeeps() {
        XCTAssertEqual(ImportDecisionChoiceWording.replaceExisting.title, "Replace Existing")
        XCTAssertEqual(
            ImportDecisionChoiceWording.replaceExisting.hint,
            "Puts the new copy in place of the one already in the library, "
                + "keeping the existing copy's reading position, bookmarks, and settings."
        )
        XCTAssertEqual(ImportDecisionChoiceWording.replaceExisting(acrossKinds: false), .replaceExisting)
        XCTAssertEqual(
            ImportDecisionChoiceWording.replaceExisting(acrossKinds: true).hint,
            "Puts the new copy in place of the one already in the library, "
                + "keeping only the existing copy's folder and place on the reading list."
        )
    }

    /// A duplicate's wording says when its copies differ in kind, so the
    /// sheet's hint promises no more than replacing keeps; no other question
    /// does (ST04 review, finding 10).
    func testTheWordingSaysWhenACopyDiffersInKind() {
        let text = Book(title: "Earlier Tide", format: .daisy, filePath: "/library/a.zip", md5Hash: "text")
        let audio = Book(title: "Tide", format: .audio, filePath: "/library/b.zip", md5Hash: "audio")
        let acrossKinds = ImportDecision(
            kind: .duplicate(.init(book: audio, existing: text, originalURL: nil, warning: nil)),
            request: ImportRequest()
        )

        XCTAssertTrue(ImportDecisionWording(for: acrossKinds, position: 1, total: 1, movesToTrash: true).replacesAcrossKinds)
        XCTAssertFalse(ImportDecisionWording(for: Self.duplicateQuestion(), position: 1, total: 1, movesToTrash: true).replacesAcrossKinds)
        XCTAssertFalse(ImportDecisionWording(for: Self.originalFileQuestion(), position: 1, total: 1, movesToTrash: true).replacesAcrossKinds)
    }

    // MARK: - What Replacing Keeps, as VoiceOver Reads It

    /// What Replace Existing keeps of a text book, and what it does not.
    private static let textKeptWords =
        "Replacing keeps the existing copy's reading position and bookmarks, moved to their words in the new text "
        + "wherever those are found, and its settings, folder, and place on the reading list. "
        + "An edit of its text is kept beside the new text as a copy, not applied to it."

    /// What Replace Existing keeps of an audiobook, and what it does not.
    private static let audioKeptWords =
        "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, "
        + "and place on the reading list, and its transcript when the audio is the same. "
        + "Edits of its audio or of its manifest are not kept."

    /// Where the old copy goes with "Move to Trash instead of deleting" on.
    private static let trashWords =
        "The existing copy's files go to the Trash, but putting them back won't return that copy to your library."

    /// Where the old copy goes with that setting off.
    private static let deletedWords = "The existing copy's files are deleted permanently and cannot be recovered."

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
