import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The import question sheet as the user meets it (TODO I01): every choice
/// has an explicit label and a hint, the choice that removes nothing comes
/// first, Return and Escape choose the marked choices, deleting a file is
/// never on a key, and the sheet announces its question. SwiftUI builds the
/// accessibility elements of its buttons only for a connected assistive
/// app, so the test that reads them skips, rather than fails, when it
/// exposes none; the wording test covers every label either way.
@MainActor
final class ImportDecisionSheetTests: XCTestCase {

    // MARK: - Wording

    /// Every choice has an explicit label and a hint saying what it does;
    /// deleting says where the file goes, as the Trash preference decides;
    /// and the folder suggested for a ZIP archive's books is the archive's
    /// own name.
    func testEveryChoiceIsLabelledAndSaysWhatItDoes() {
        let choices: [ImportDecisionChoiceWording] = [
            .keepBoth, .replaceExisting, .cancelDuplicate, .keepOriginal,
            .deleteOriginal(OriginalFileDeletionWording(movesToTrash: true)),
            .deleteOriginal(OriginalFileDeletionWording(movesToTrash: false)),
            .createFolder, .declineFolder,
        ]
        for choice in choices {
            XCTAssertFalse(choice.title.isEmpty)
            XCTAssertTrue(choice.hint.hasSuffix("."), choice.hint)
        }
        XCTAssertEqual(
            ImportDecisionChoiceWording.deleteOriginal(OriginalFileDeletionWording(movesToTrash: true)),
            ImportDecisionChoiceWording(title: "Move to Trash", hint: "You can recover it from the Trash until the Trash is emptied.")
        )
        XCTAssertEqual(
            ImportDecisionChoiceWording.deleteOriginal(OriginalFileDeletionWording(movesToTrash: false)),
            ImportDecisionChoiceWording(title: "Delete Permanently", hint: "It cannot be recovered.")
        )
        XCTAssertEqual(ImportDecisionChoiceWording.folderNameLabel, "Folder name")
        let batch = ImportDecision.ZipBatch(
            archiveURL: URL(fileURLWithPath: "/Downloads/Chart Shelf.zip"),
            books: [],
            folderPath: ""
        )
        XCTAssertEqual(batch.suggestedFolderName, "Chart Shelf")
    }

    // MARK: - The Rendered Sheet

    /// The duplicate question's sheet offers Keep Both first, then Replace
    /// Existing and Cancel, each with its label and hint, and pressing a
    /// button through accessibility answers with its choice.
    func testTheDuplicateSheetLabelsItsChoicesAndAnswersWithThem() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let answers = CallLog<ImportDecisionAnswer>()
        let sheet = makeSheet(for: Self.duplicateQuestion(), answers: answers)

        try withHostedView(sheet, until: { !self.buttons(in: $0).isEmpty }) { hostingView in
            let found = buttons(in: hostingView)
            guard !found.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            XCTAssertEqual(found.map(\.label), ["Keep Both", "Replace Existing", "Cancel"])
            XCTAssertEqual(found.map(\.hint), [
                ImportDecisionChoiceWording.keepBoth.hint,
                ImportDecisionChoiceWording.replaceExisting.hint,
                ImportDecisionChoiceWording.cancelDuplicate.hint,
            ])
            XCTAssertTrue(found[1].element.accessibilityPerformPress())
            XCTAssertTrue(waitUntil { answers.calls == [.replaceExisting] }, "answered \(answers.calls)")
        }
    }

    /// Return keeps both copies of a duplicate and Escape cancels, as the
    /// default and cancel keys do in any Mac dialog.
    func testReturnKeepsBothAndEscapeCancelsADuplicate() throws {
        let answers = CallLog<ImportDecisionAnswer>()
        let sheet = makeSheet(for: Self.duplicateQuestion(), answers: answers)

        try withHostedView(sheet, until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { answers.calls == [.keepBoth] }, "Return answered \(answers.calls)")
            // The choices are dimmed while an answer is carried out, a moment
            // after it is recorded, so Escape is tried until it is taken.
            XCTAssertTrue(waitUntil { pressKeyEquivalent(.escape, in: hostingView) }, "Escape was never taken")
            XCTAssertTrue(waitUntil { answers.calls == [.keepBoth, .cancel] }, "Escape answered \(answers.calls)")
        }
    }

    /// Return never deletes an original file, and Escape keeps it.
    func testReturnNeverDeletesAnOriginalAndEscapeKeepsIt() throws {
        let answers = CallLog<ImportDecisionAnswer>()
        let sheet = makeSheet(for: Self.originalFileQuestion(), answers: answers)

        try withHostedView(sheet, until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.escape, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { answers.calls == [.cancel] }, "Escape answered \(answers.calls)")
            _ = pressKeyEquivalent(.return, in: hostingView)
            XCTAssertEqual(answers.calls, [.cancel], "Return answered the question")
        }
    }

    /// Once a question appears, the sheet announces it, title first, after
    /// the delay that lets VoiceOver reach the first control.
    func testTheSheetAnnouncesItsQuestion() {
        let decision = Self.duplicateQuestion()
        let wording = ImportDecisionWording(for: decision, position: 2, total: 3, movesToTrash: true)
        let announced = CallLog<String>()
        let sheet = ImportDecisionSheet(
            decision: decision,
            wording: wording,
            voiceOverDelay: 0,
            onAnswer: { _ in .success(nil) },
            announce: { announced.record($0) }
        )

        withHostedView(sheet, until: { $0.fittingSize.height > 0 }) { _ in
            XCTAssertTrue(waitUntil(timeout: 10) { !announced.calls.isEmpty }, "the question was never announced")
            XCTAssertEqual(announced.calls, [wording.announcement])
        }
    }

    // MARK: - Fixtures

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

    /// The sheet for `decision`, alone and the only question, recording its
    /// answers in `answers` and announcing nothing.
    private func makeSheet(for decision: ImportDecision, answers: CallLog<ImportDecisionAnswer>) -> ImportDecisionSheet {
        ImportDecisionSheet(
            decision: decision,
            wording: ImportDecisionWording(for: decision, position: 1, total: 1, movesToTrash: true),
            voiceOverDelay: 0,
            onAnswer: { answer in
                answers.record(answer)
                return .success(nil)
            },
            announce: { _ in }
        )
    }

    /// The buttons VoiceOver can land on below `root`.
    private func buttons(in root: Any) -> [AccessibleControl] {
        accessibleControls(in: root).filter { $0.role == .button }
    }
}
