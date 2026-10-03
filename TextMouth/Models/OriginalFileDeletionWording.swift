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

    /// A deletion that failed, then `reason`, as one sentence: "The original
    /// file “Notes.epub” could not be moved to the Trash: <reason>".
    func failureSentence(reason: String) -> String {
        let action = mode == .moveToTrash ? "moved to the Trash" : "deleted"
        return subject.prefix(1).uppercased() + subject.dropFirst() + " could not be \(action): \(reason)"
    }
}
