import Foundation

/// The words for deleting the original file of a book just imported, in the
/// mode the Trash preference chooses (TODO S09). The "After Importing a
/// Book" preference deletes it automatically or asks first, and the
/// deletion goes to the Trash or is permanent like every other removal, so
/// these words are built from `RemovalMode` and always say which.
///
/// Every sentence is a whole localized string for each mode and each way of
/// naming the file (FR34), never an English verb glued to a noun.
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

    // MARK: The Confirmation

    /// The confirmation's title: "Move Original File to Trash?" or "Delete
    /// Original File Permanently?"
    var confirmationTitle: String {
        if mode == .moveToTrash {
            // Translators: Title of the confirmation that asks whether to move the original file of a book just imported to the Trash. Title case.
            return InterfaceText.line("originalFileDeletion.confirmTrashTitle", "Move Original File to Trash?")
        }
        // Translators: Title of the confirmation that asks whether to delete the original file of a book just imported permanently. Title case.
        return InterfaceText.line("originalFileDeletion.confirmDeleteTitle", "Delete Original File Permanently?")
    }

    /// The confirmation's deleting button: "Move to Trash" or "Delete
    /// Permanently". The title and message name the file.
    var buttonTitle: String {
        mode.buttonTitle()
    }

    /// What the confirmation asks: "The book was imported.
    /// Move the original file “Notes.epub” to the Trash? You can recover it
    /// from the Trash until the Trash is emptied."
    var confirmationMessage: String {
        // Translators: First sentence of the confirmation that asks about deleting the original file of a book just imported. The question about the file follows it.
        let imported = InterfaceText.line("originalFileDeletion.confirmationMessage", "The book was imported.")
        return SentenceWording.joined([imported, question, consequence])
    }

    /// The question of the confirmation: whether to move or delete the
    /// original file, by name when the name is known. One whole sentence for
    /// each mode and each way of naming the file.
    private var question: String {
        switch (mode == .moveToTrash, fileName) {
        case (true, let name?):
            // Translators: Question of the confirmation about the original file of a book just imported. %@ is the file's name.
            return InterfaceText.line("originalFileDeletion.question.moveNamed", "Move the original file “\(name)” to the Trash?")
        case (true, nil):
            // Translators: Question of the confirmation about the original file of a book just imported, when the file's name is not known.
            return InterfaceText.line("originalFileDeletion.question.moveTrash", "Move the original file to the Trash?")
        case (false, let name?):
            // Translators: Question of the confirmation about the original file of a book just imported. %@ is the file's name.
            return InterfaceText.line("originalFileDeletion.question.deleteNamed", "Delete the original file “\(name)” permanently?")
        case (false, nil):
            // Translators: Question of the confirmation about the original file of a book just imported, when the file's name is not known.
            return InterfaceText.line("originalFileDeletion.question.deletePermanently", "Delete the original file permanently?")
        }
    }

    /// What becomes of the file once it is removed this way.
    var consequence: String {
        mode == .moveToTrash
            // Translators: Sentence of the confirmation about the original file of a book just imported, and the hint of its Move to Trash button: the file can be recovered from the Trash.
            ? InterfaceText.line("originalFileDeletion.consequence.recover", "You can recover it from the Trash until the Trash is emptied.")
            // Translators: Sentence of the confirmation about the original file of a book just imported, and the hint of its Delete Permanently button: the file is gone for good.
            : InterfaceText.line("originalFileDeletion.consequence.recovered", "It cannot be recovered.")
    }

    // MARK: Storage Settings

    /// What "Delete After Import" does, as Storage settings explain it:
    /// "The original file will be moved to the Trash after a successful
    /// import."
    var automaticDeletionExplanation: String {
        mode == .moveToTrash
            // Translators: Caption in Storage settings under the choice that deletes the original file after an import, while files go to the Trash.
            ? InterfaceText.line("originalFileDeletion.trashAfterImport", "The original file will be moved to the Trash after a successful import.")
            // Translators: Caption in Storage settings under the choice that deletes the original file after an import, while files are deleted permanently.
            : InterfaceText.line("originalFileDeletion.deleteAfterImport", "The original file will be permanently deleted after a successful import.")
    }

    /// What "Ask Each Time" does, as Storage settings explain it: "You will
    /// be asked whether to move the original file to the Trash after each
    /// import."
    var askingExplanation: String {
        mode == .moveToTrash
            // Translators: Caption in Storage settings under the choice that asks about the original file after each import, while files go to the Trash.
            ? InterfaceText.line("originalFileDeletion.askingExplanation.trash", "You will be asked whether to move the original file to the Trash after each import.")
            // Translators: Caption in Storage settings under the choice that asks about the original file after each import, while files are deleted permanently.
            : InterfaceText.line("originalFileDeletion.asking.permanently", "You will be asked whether to delete the original file permanently after each import.")
    }

    // MARK: Failure

    /// A deletion that failed, then `reason`, as one sentence: "The original
    /// file “Notes.epub” could not be moved to the Trash: <reason>".
    func failureSentence(reason: String) -> String {
        switch (mode == .moveToTrash, fileName) {
        case (true, let name?):
            // Translators: Alert about the original file of an imported book that could not be moved to the Trash. %1$@ is the file's name and %2$@ the reason, a sentence of the system's.
            return InterfaceText.line("originalFileDeletion.failureSentence.value", "The original file “\(name)” could not be moved to the Trash: \(reason)")
        case (true, nil):
            // Translators: Alert about the original file of an imported book that could not be moved to the Trash, its name not known. %@ is the reason, a sentence of the system's.
            return InterfaceText.line("originalFileDeletion.failureSentence.notMoved", "The original file could not be moved to the Trash: \(reason)")
        case (false, let name?):
            // Translators: Alert about the original file of an imported book that could not be deleted. %1$@ is the file's name and %2$@ the reason, a sentence of the system's.
            return InterfaceText.line("originalFileDeletion.failureSentence.valueNot", "The original file “\(name)” could not be deleted: \(reason)")
        case (false, nil):
            // Translators: Alert about the original file of an imported book that could not be deleted, its name not known. %@ is the reason, a sentence of the system's.
            return InterfaceText.line("originalFileDeletion.failureSentence.notDeleted", "The original file could not be deleted: \(reason)")
        }
    }
}
