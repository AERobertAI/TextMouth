import Foundation

/// What the iPhone's import question sheet shows for the question an import
/// waits on (the spec's "Import questions"): the Mac's title and message,
/// then the Mac's choices with their words and hints, in a vertical list in
/// the Mac's order, and for a ZIP archive's books the Mac's folder name
/// field.
///
/// On iOS the Mac's presenter never shows a question, so without this sheet
/// a duplicate would wait for ever. Two kinds are never shown, and are
/// answered at once instead (`automaticAnswer(for:)`): the question whether
/// to delete an original file, since every original the shared import sees
/// on the phone is a scratch copy the app made, which the spec says is never
/// asked about; and the offer to transcribe, which the phone can't do yet.
struct PhoneImportQuestion: Equatable, Identifiable {
    /// One choice in the list.
    struct Choice: Equatable, Identifiable {
        /// What the choice answers, with the folder name for Create Folder
        /// read when it is pressed.
        enum Action: Equatable {
            case keepBoth
            case replaceExisting
            case cancel
            case createFolder
        }

        /// The Mac's title, which is the button's label, and its hint.
        let words: ImportDecisionChoiceWording
        /// What pressing it answers.
        let action: Action

        /// Tells the choices apart in a list: no question has two of one.
        var id: String { "\(action)" }

        /// The answer this choice gives, with `folderName` the text of the
        /// folder name field for Create Folder.
        func answer(folderName: String) -> ImportDecisionAnswer {
            switch action {
            case .keepBoth: return .keepBoth
            case .replaceExisting: return .replaceExisting
            case .cancel: return .cancel
            case .createFolder: return .createFolder(named: folderName)
            }
        }
    }

    /// The question it shows, whose answer must name it.
    let decisionID: ImportDecision.ID

    /// Tells one question's sheet from the next one's.
    var id: ImportDecision.ID { decisionID }
    /// The Mac's title, with its place among the questions waiting: the
    /// sheet's heading.
    let title: String
    /// The Mac's question, where focus lands as the sheet appears.
    let message: String
    /// The choices, in the order the list shows them.
    let choices: [Choice]
    /// For a ZIP archive's books, the folder name field's first text, the
    /// archive's name without its extension; nil when the question has no
    /// field.
    let suggestedFolderName: String?
    /// For a duplicate, the new copy's title, which the sheet names while
    /// Replace Existing works (`DuplicateCopyWording.replacing(bookTitle:)`);
    /// nil for any other question.
    let duplicateTitle: String?

    /// The sheet for `decision`, whose words are `wording`; nil for a
    /// question the phone answers itself (`automaticAnswer(for:)`).
    init?(decision: ImportDecision, wording: ImportDecisionWording) {
        decisionID = decision.id
        title = wording.title
        message = wording.message
        switch decision.kind {
        case .duplicate(let duplicate):
            duplicateTitle = duplicate.book.title
            // "Keep Both", "Replace Existing", "Cancel": the Mac's row, top
            // to bottom, the choice that removes nothing first.
            choices = [
                Choice(words: .keepBoth, action: .keepBoth),
                Choice(words: .replaceExisting(acrossKinds: wording.replacesAcrossKinds), action: .replaceExisting),
                Choice(words: .cancelDuplicate, action: .cancel),
            ]
            suggestedFolderName = nil
        case .zipFolder(let batch):
            choices = [
                Choice(words: .createFolder, action: .createFolder),
                Choice(words: .declineFolder, action: .cancel),
            ]
            suggestedFolderName = batch.suggestedFolderName
            duplicateTitle = nil
        case .originalFile, .transcriptionOffer:
            return nil
        }
    }

    /// The answer the phone gives at once to a question of `kind`, which it
    /// never shows: Keep for an original file, which is the app's own
    /// scratch copy, swept once the import is over; Not Now for an offer to
    /// transcribe. Nil for the questions the sheet asks.
    static func automaticAnswer(for kind: ImportDecision.Kind) -> ImportDecisionAnswer? {
        switch kind {
        case .originalFile, .transcriptionOffer: return .cancel
        case .duplicate, .zipFolder: return nil
        }
    }

    /// Whether Create Folder can be pressed with `folderName` in the field:
    /// when it makes a folder name, by the Mac's rule, as its sheet dims the
    /// button.
    static func canCreateFolder(named folderName: String) -> Bool {
        BookFolder.normalizedName(folderName) != nil
    }

    /// Whether `choice` can be pressed with `folderName` in the field: every
    /// choice but Create Folder always can.
    func isEnabled(_ choice: Choice, folderName: String) -> Bool {
        choice.action != .createFolder || Self.canCreateFolder(named: folderName)
    }
}
