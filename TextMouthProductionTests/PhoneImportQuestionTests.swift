import XCTest
@testable import TextMouth

/// `PhoneImportQuestion`: what the iPhone's question sheet shows for each
/// kind of import question, in the Mac's words and order, and which kinds the
/// phone answers itself, so that no question waits for ever.
final class PhoneImportQuestionTests: XCTestCase {

    // MARK: - Fixtures

    /// A book of `format` titled `title`, imported from `source`.
    private func book(_ title: String, format: BookFormat = .epub, source: String? = nil) -> Book {
        Book(
            title: title,
            format: format,
            filePath: "/tmp/\(title).\(format.rawValue)",
            md5Hash: "hash-\(title)",
            sourceFilePath: source
        )
    }

    /// The words of `decision`, as the library builds them on the phone, with
    /// files deleted, never moved to a Trash.
    private func wording(_ decision: ImportDecision) -> ImportDecisionWording {
        ImportDecisionWording(for: decision, position: 1, total: 1, movesToTrash: false)
    }

    // MARK: - Duplicates

    /// A duplicate shows the Mac's title and question, then Keep Both,
    /// Replace Existing, and Cancel, top to bottom, with the Mac's hints.
    func testDuplicateListsTheMacsThreeChoicesInOrder() throws {
        let duplicate = ImportDecision.DuplicateBook(
            book: book("Dune", source: "/tmp/PhoneImport/A/Dune.epub"),
            existing: book("Dune"),
            originalURL: nil,
            warning: nil
        )
        let decision = ImportDecision(kind: .duplicate(duplicate), request: ImportRequest())
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording(decision)))

        XCTAssertEqual(question.decisionID, decision.id)
        XCTAssertEqual(question.title, "Duplicate Book Found")
        XCTAssertTrue(question.message.hasPrefix("“Dune.epub” matches “Dune”, which is already in your library."), question.message)
        XCTAssertEqual(question.choices.map(\.words.title), ["Keep Both", "Replace Existing", "Cancel"])
        XCTAssertEqual(question.choices.map(\.words.hint), [
            ImportDecisionChoiceWording.keepBoth.hint,
            ImportDecisionChoiceWording.replaceExisting.hint,
            ImportDecisionChoiceWording.cancelDuplicate.hint,
        ])
        XCTAssertEqual(question.choices.map { $0.answer(folderName: "") }, [.keepBoth, .replaceExisting, .cancel])
        XCTAssertNil(question.suggestedFolderName)
    }

    /// On the phone, the old copy's files are deleted: the question never
    /// says they go to a Trash.
    func testDuplicateSaysTheOldCopyIsDeletedNotTrashed() throws {
        let duplicate = ImportDecision.DuplicateBook(book: book("Dune"), existing: book("Dune"), originalURL: nil, warning: nil)
        let decision = ImportDecision(kind: .duplicate(duplicate), request: ImportRequest())
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording(decision)))

        XCTAssertFalse(question.message.contains("Trash"), question.message)
        XCTAssertTrue(question.message.contains("The existing copy's files are deleted"), question.message)
    }

    /// Copies of different kinds take Replace Existing's other hint, which
    /// promises only the folder and the place on the reading list.
    func testDuplicateAcrossKindsTakesTheOtherHint() throws {
        let duplicate = ImportDecision.DuplicateBook(
            book: book("Dune", format: .audio),
            existing: book("Dune", format: .epub),
            originalURL: nil,
            warning: nil
        )
        let decision = ImportDecision(kind: .duplicate(duplicate), request: ImportRequest())
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording(decision)))

        XCTAssertEqual(question.choices[1].words, ImportDecisionChoiceWording.replaceExistingAcrossKinds)
    }

    // MARK: - A ZIP Archive's Books

    /// A ZIP archive's books offer Create Folder and No Thanks, with the
    /// archive's name in the field, and Create Folder answers with the
    /// field's text.
    func testZipFolderOffersCreateFolderAndNoThanks() throws {
        let batch = ImportDecision.ZipBatch(
            archiveURL: URL(fileURLWithPath: "/tmp/PhoneImport/B/Mac Books.zip"),
            books: [book("Dune"), book("Emma")],
            folderPath: ""
        )
        let decision = ImportDecision(kind: .zipFolder(batch), request: ImportRequest())
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording(decision)))

        XCTAssertEqual(question.title, "Create Folder for Imported Books?")
        XCTAssertEqual(question.choices.map(\.words.title), ["Create Folder", "No Thanks"])
        XCTAssertEqual(question.suggestedFolderName, "Mac Books")
        XCTAssertEqual(question.choices[0].answer(folderName: "Novels"), .createFolder(named: "Novels"))
        XCTAssertEqual(question.choices[1].answer(folderName: "Novels"), .cancel)
    }

    /// Create Folder is dimmed for a name that makes no folder, by the Mac's
    /// rule; No Thanks never is.
    func testCreateFolderNeedsAName() throws {
        let batch = ImportDecision.ZipBatch(archiveURL: URL(fileURLWithPath: "/tmp/x.zip"), books: [], folderPath: "")
        let decision = ImportDecision(kind: .zipFolder(batch), request: ImportRequest())
        let question = try XCTUnwrap(PhoneImportQuestion(decision: decision, wording: wording(decision)))

        XCTAssertFalse(question.isEnabled(question.choices[0], folderName: "   "))
        XCTAssertTrue(question.isEnabled(question.choices[0], folderName: "Novels"))
        XCTAssertTrue(question.isEnabled(question.choices[1], folderName: ""))
    }

    // MARK: - Answered by the Phone

    /// An original file's question and an offer to transcribe are never
    /// shown: the phone keeps its own scratch copy, and can't transcribe yet.
    func testOriginalFileAndTranscriptionAreAnsweredAtOnce() {
        let original = ImportDecision(
            kind: .originalFile(.init(url: URL(fileURLWithPath: "/tmp/PhoneImport/C/Dune.epub"), bookID: UUID())),
            request: ImportRequest()
        )
        let offer = ImportDecision(
            kind: .transcriptionOffer(.init(bookID: UUID(), bookTitle: "Dune", audioSeconds: 60)),
            request: ImportRequest()
        )

        XCTAssertNil(PhoneImportQuestion(decision: original, wording: wording(original)))
        XCTAssertNil(PhoneImportQuestion(decision: offer, wording: wording(offer)))
        XCTAssertEqual(PhoneImportQuestion.automaticAnswer(for: original.kind), .cancel)
        XCTAssertEqual(PhoneImportQuestion.automaticAnswer(for: offer.kind), .cancel)
        // Both answers are ones those questions take, so the queue moves on.
        XCTAssertTrue(ImportDecisionAnswer.cancel.fits(original.kind))
        XCTAssertTrue(ImportDecisionAnswer.cancel.fits(offer.kind))
    }

    /// The questions the sheet asks are never answered by the phone.
    func testShownQuestionsHaveNoAutomaticAnswer() {
        let duplicate = ImportDecision.DuplicateBook(book: book("Dune"), existing: book("Dune"), originalURL: nil, warning: nil)
        let batch = ImportDecision.ZipBatch(archiveURL: URL(fileURLWithPath: "/tmp/x.zip"), books: [], folderPath: "")
        XCTAssertNil(PhoneImportQuestion.automaticAnswer(for: .duplicate(duplicate)))
        XCTAssertNil(PhoneImportQuestion.automaticAnswer(for: .zipFolder(batch)))
    }
}
