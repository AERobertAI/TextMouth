import Foundation

/// The words for deleting the original file of a book just imported, in the
/// mode the Trash preference chooses (TODO S09). The "After Importing a
/// Book" preference deletes it automatically or asks first, and the
/// deletion goes to the Trash or is permanent like every other removal, so
/// these words are built from `RemovalMode` and always say which.
struct OriginalFileDeletionWording: Equatable {
    /// To the Trash, or permanently.
    let mode: RemovalMode
    /// The file's name, when one is known.
    let fileName: String?

    /// The words for deleting the file named `fileName` with "Move to Trash
    /// instead of deleting" set to `movesToTrash`.
    init(movesToTrash: Bool, fileName: String? = nil) {
        mode = .deleting(movesToTrash: movesToTrash)
        self.fileName = fileName
    }

    /// The file as a sentence names it: "the original file “Notes.epub”",
    /// or "the original file" when its name is not known.
    var subject: String {
        guard let fileName else { return "the original file" }
        return "the original file “\(fileName)”"
    }

    // MARK: The Confirmation

    /// The confirmation's title: "Move Original File to Trash?" or "Delete
    /// Original File Permanently?"
    var confirmationTitle: String {
        mode.buttonTitle("Original File") + "?"
    }

    /// The confirmation's deleting button: "Move to Trash" or "Delete
    /// Permanently". The title and message name the file.
    var buttonTitle: String {
        mode.buttonTitle()
    }

    /// What the confirmation asks: "The book has been imported successfully.
    /// Move the original file “Notes.epub” to the Trash? You can recover it
    /// from the Trash until the Trash is emptied."
    var confirmationMessage: String {
        "The book has been imported successfully. \(mode.spokenAction(subject))? \(consequence)"
    }

    /// What becomes of the file once it is removed this way.
    var consequence: String {
        mode == .moveToTrash
            ? "You can recover it from the Trash until the Trash is emptied."
            : "It cannot be recovered."
    }

    // MARK: Storage Settings

    /// What "Delete After Import" does, as Storage settings explain it:
    /// "The original file will be moved to the Trash after a successful
    /// import."
    var automaticDeletionExplanation: String {
        mode == .moveToTrash
            ? "The original file will be moved to the Trash after a successful import."
            : "The original file will be permanently deleted after a successful import."
    }

    /// What "Ask Each Time" does, as Storage settings explain it: "You will
    /// be asked whether to move the original file to the Trash after each
    /// import."
    var askingExplanation: String {
        let action = mode.spokenAction("the original file")
        return "You will be asked whether to \(action.prefix(1).lowercased() + action.dropFirst()) after each import."
    }

    // MARK: Failure

    /// A deletion that failed, then `reason`, as one sentence: "The original
    /// file “Notes.epub” could not be moved to the Trash: <reason>".
    func failureSentence(reason: String) -> String {
        let action = mode == .moveToTrash ? "moved to the Trash" : "deleted"
        return subject.prefix(1).uppercased() + subject.dropFirst() + " could not be \(action): \(reason)"
    }
}
