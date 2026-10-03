import XCTest
@testable import TextMouth

// Shared fixtures for the tests that meet import questions (TODO I01): the
// duplicate, original-file, and ZIP folder questions the library queues.

extension ImportDecision {
    /// The duplicate this question is about, or nil for another kind.
    var duplicate: DuplicateBook? {
        guard case .duplicate(let duplicate) = kind else { return nil }
        return duplicate
    }

    /// The original file this question is about, or nil for another kind.
    var originalFile: OriginalFile? {
        guard case .originalFile(let original) = kind else { return nil }
        return original
    }

    /// The ZIP archive's books this question is about, or nil for another
    /// kind.
    var zipBatch: ZipBatch? {
        guard case .zipFolder(let batch) = kind else { return nil }
        return batch
    }
}

extension LibraryViewModel {
    /// Answers the question being asked with `answer`, as the button the
    /// question sheet shows for it does, and fails the test when no question
    /// is being asked.
    @discardableResult
    func answerCurrentImportDecision(
        _ answer: ImportDecisionAnswer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OperationOutcome {
        guard let decision = importDecisions.current else {
            XCTFail("No import question is being asked", file: file, line: line)
            return .failure("No import question is being asked.")
        }
        return answerImportDecision(decision.id, with: answer)
    }
}

extension XCTestCase {
    /// Sets the "After Importing a Book" preference to `behavior` until the
    /// test ends, then puts back the preference it found. Imports read it as
    /// they finish, and answers read it too, so it holds for the whole test.
    @MainActor
    func useAfterImportingBehavior(_ behavior: ImportDeleteBehavior) {
        let previous = ConfigService.shared.config.importDeleteBehavior
        ConfigService.shared.config.importDeleteBehavior = behavior
        addTeardownBlock {
            await MainActor.run { ConfigService.shared.config.importDeleteBehavior = previous }
        }
    }

    /// Turns "Move to Trash instead of deleting" off until the test ends, so
    /// nothing the test deletes, a package or an original file, reaches the
    /// user's real Trash.
    @MainActor
    func keepDeletionsOutOfTheTrash() {
        let previous = ConfigService.shared.config.moveToTrashInsteadOfDeleting
        ConfigService.shared.config.moveToTrashInsteadOfDeleting = false
        addTeardownBlock {
            await MainActor.run { ConfigService.shared.config.moveToTrashInsteadOfDeleting = previous }
        }
    }
}

/// Records the books a library model opens after importing them, in
/// place of opening reader windows (`LibraryViewModel.readerOpener`).
@MainActor
final class OpenedBooks {
    /// The books opened so far, in order.
    private(set) var ids: [UUID] = []

    /// Makes `model` record the books it opens here instead of opening them.
    init(recordingFor model: LibraryViewModel) {
        // Weak: an import still running when the test ends may open a book
        // after this recorder is gone.
        model.readerOpener = { [weak self] bookID in
            self?.ids.append(bookID)
        }
    }
}
