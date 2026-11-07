import Combine
import Foundation

// MARK: - What a Sheet Acts On, and What It Did

/// Which of the iPhone's folder sheets is open, and what it acts on (the
/// iPhone interface spec, "Folder sheets").
enum PhoneFolderSheetTask {
    /// New Folder, making a folder inside the folder at `parentPath` ("" for
    /// the library's top level), as the Library shows it when New Folder is
    /// chosen.
    case newFolder(parentPath: String)
    /// Rename Folder, for this folder.
    case renameFolder(BookFolder)
    /// Move Folder, moving this folder under another parent.
    case moveFolder(BookFolder)
    /// Move to Folder, moving these books into another folder.
    case moveBooks([Book])
    /// Move to Folder's New Folder..., making a folder that becomes the
    /// books' destination, as the Mac's folder picker makes one.
    case newFolderForMove
    /// Delete Folder, for a folder holding something: the Mac's question,
    /// with its Move Contents choice and its Delete Everything choice.
    case deleteFolder(BookFolder)
}

/// What a folder sheet did, handed to its presenter as it closes after a
/// success, so the Library can tell where focus goes. A sheet that closes
/// with nothing done, by Cancel or by VoiceOver's scrub, hands nothing over:
/// the presenter's `onDismiss` returns focus either way.
enum PhoneFolderSheetResult: Equatable {
    /// New Folder made the folder at `path`.
    case createdFolder(path: String)
    /// Rename Folder renamed the folder `id`, now at `path`.
    case renamedFolder(id: UUID, path: String)
    /// Move Folder moved the folder `id`, now at `path`.
    case movedFolder(id: UUID, path: String)
    /// Move to Folder moved the books `ids` into the folder at `path` ("" for
    /// the library's top level).
    case movedBooks(ids: [UUID], path: String)
    /// Delete Folder deleted the folder `id`, after moving its contents to
    /// `contentsMovedTo` ("" for the top level), or with everything in it when
    /// that is nil.
    case deletedFolder(id: UUID, contentsMovedTo: String?)
}

/// A folder sheet to present: its task, with an identity of its own, so the
/// Library presents every folder sheet through one `sheet(item:)`, and a
/// second request opens a sheet of its own rather than reusing the first.
struct PhoneFolderSheetRequest: Identifiable {
    /// Tells two requests apart.
    let id = UUID()
    /// Which sheet, and what it acts on.
    let task: PhoneFolderSheetTask
}

/// Where VoiceOver's focus lands as a folder sheet's form arrives: on what
/// the sheet is for (the spec, "Focus on arrival and return").
enum PhoneFolderSheetArrival: Hashable, Sendable {
    /// The name field, which also takes the keyboard.
    case nameField
    /// The row choosing the folder.
    case folderRow
}

/// Delete Folder...'s first step, which the Mac takes the same way.
enum PhoneFolderDeleteStart: Equatable {
    /// The folder held nothing, so it was removed at once, with no question.
    case removedAtOnce
    /// The folder holds something, so the Delete Folder sheet asks first.
    case asks
}

// MARK: - The Library Calls

/// The library calls the folder sheets make: by default the Mac's own
/// (`LibraryViewModel+FolderManagement`, `moveBooksReturningOutcome`), each of
/// which presents nothing and reports what happened, so a sheet can stay open
/// with the reason. Tests hand in their own, so no test touches a disk.
struct PhoneFolderOperations {
    /// Makes a folder named `name` in the folder at `parentPath`.
    var createFolder: @MainActor (_ name: String, _ parentPath: String) -> OperationOutcome
    /// Renames `folder` to `name`.
    var renameFolder: @MainActor (_ folder: BookFolder, _ name: String) async -> OperationOutcome
    /// Moves `folder` under the folder at `parentPath`.
    var moveFolder: @MainActor (_ folder: BookFolder, _ parentPath: String) async -> OperationOutcome
    /// Moves `books` into the folder at `path`.
    var moveBooks: @MainActor (_ books: [Book], _ path: String) async -> OperationOutcome
    /// Moves `folder`'s contents to the folder at `path`, then deletes it.
    var removeFolderMovingContents: @MainActor (_ folder: BookFolder, _ path: String) async -> OperationOutcome
    /// Deletes `folder` and everything in it. The library's own error alert
    /// names whatever couldn't be deleted, as on the Mac.
    var removeFolderAndEverything: @MainActor (_ folder: BookFolder) -> Void

    /// The Mac's own calls on `library`.
    @MainActor
    static func calling(_ library: LibraryViewModel) -> PhoneFolderOperations {
        PhoneFolderOperations(
            createFolder: { library.createFolderReturningOutcome(name: $0, parentPath: $1) },
            renameFolder: { await library.renameFolderReturningOutcome($0, to: $1) },
            moveFolder: { await library.moveFolderReturningOutcome($0, toParent: $1) },
            moveBooks: { await library.moveBooksReturningOutcome($0, toFolder: $1) },
            removeFolderMovingContents: { await library.removeFolderMovingContentsReturningOutcome($0, toPath: $1) },
            removeFolderAndEverything: { library.removeFolderAndEverything($0) }
        )
    }
}

// MARK: - The Model

/// Everything a folder sheet on the iPhone decides, so that its SwiftUI view
/// only shows it and calls it, and the Mac's test host can test it: the
/// sheet's words, what is typed and chosen, whether the confirm button is
/// enabled, the folders offered, the work under way, a failure's reason, and
/// the sentence said once the sheet has closed.
///
/// Each rule is the Mac's own sheet's (`Views/Library/LibrarySheetViews.swift`),
/// over the same library calls: a failure keeps the sheet open with what was
/// typed and chosen, shows the reason, and says it once; a change to what was
/// typed or chosen clears it.
@MainActor
final class PhoneFolderSheetModel: ObservableObject {
    /// Which sheet this is, and what it acts on.
    let task: PhoneFolderSheetTask

    /// The name typed: New Folder's new name, or Rename Folder's, which starts
    /// as the folder's own. Changing it clears a failure about the last one.
    @Published var name: String {
        didSet {
            if name != oldValue { failureMessage = nil }
        }
    }

    /// The path of the folder chosen ("" for the library's top level): New
    /// Folder's parent, Move Folder's new parent, Move to Folder's
    /// destination, or where Delete Folder moves the contents. Changing it
    /// clears a failure about the last one.
    @Published var destination: String {
        didSet {
            if destination != oldValue { failureMessage = nil }
        }
    }

    /// Why the last attempt failed, shown until what it was about changes.
    @Published private(set) var failureMessage: String?
    /// Whether the sheet's work is under way: its buttons are dimmed and it
    /// can't be closed meanwhile, so the work can't start twice or be left
    /// halfway.
    @Published private(set) var isWorking = false

    /// The library the sheet edits, read for its folders and counts.
    private let library: LibraryViewModel
    /// The calls that make the edits.
    private let operations: PhoneFolderOperations
    /// Says a failure, once, as it happens.
    private let announce: @MainActor (String) -> Void
    /// Says what the sheet did, once it has closed.
    private let announceAfterClosing: @MainActor (String) -> Void

    /// A model for `task` over `library`. The calls, and the two ways of
    /// speaking, are the app's own unless a test hands in others: a failure
    /// is said a moment after the button that caused it, so SwiftUI's own
    /// layout notification can't cut it off (`PhoneAnnouncer.say`), and the
    /// sentence after is said once the sheet has closed, as the Mac's Library
    /// window says it (`VoiceOverAnnouncer.announceAfterSheetCloses`).
    init(
        task: PhoneFolderSheetTask,
        library: LibraryViewModel,
        operations: PhoneFolderOperations? = nil,
        announce: (@MainActor (String) -> Void)? = nil,
        announceAfterClosing: (@MainActor (String) -> Void)? = nil
    ) {
        self.task = task
        self.library = library
        self.operations = operations ?? .calling(library)
        self.announce = announce ?? { PhoneAnnouncer.say($0) }
        self.announceAfterClosing = announceAfterClosing ?? { VoiceOverAnnouncer.announceAfterSheetCloses($0, from: nil) }
        _name = Published(initialValue: Self.initialName(for: task))
        _destination = Published(initialValue: Self.initialDestination(for: task, in: library))
    }

    // MARK: Words

    /// The sheet's title, read as its heading: the Mac's sheet's heading.
    var title: String {
        switch task {
        case .newFolder, .newFolderForMove: return PhoneFolderVocabulary.newFolderTitle
        case .renameFolder: return PhoneFolderVocabulary.renameFolderTitle
        case .moveFolder(let folder): return PhoneFolderVocabulary.moveFolderTitle(folderName: folder.name)
        case .moveBooks(let books): return PhoneFolderVocabulary.moveBooksTitle(titles: books.map(\.title))
        case .deleteFolder: return PhoneFolderVocabulary.deleteFolderTitle
        }
    }

    /// The button that does the sheet's work: Create, Rename, Move, or, on
    /// Delete Folder's Move Contents screen, Move Contents & Delete Folder.
    var confirmTitle: String {
        switch task {
        case .newFolder, .newFolderForMove: return PhoneFolderVocabulary.create
        case .renameFolder: return PhoneFolderVocabulary.rename
        case .moveFolder, .moveBooks: return PhoneFolderVocabulary.move
        case .deleteFolder: return PhoneFolderVocabulary.moveContentsAndDelete
        }
    }

    /// What the sheet says while its work is under way, as the Mac's work
    /// indicator does. New Folder's work ends at once, so it has none.
    var workLabel: String? {
        switch task {
        case .newFolder, .newFolderForMove: return nil
        case .renameFolder: return PhoneFolderVocabulary.renamingFolder
        case .moveFolder: return PhoneFolderVocabulary.movingFolder
        case .moveBooks(let books): return PhoneFolderVocabulary.movingBooks(count: books.count)
        case .deleteFolder: return PhoneFolderVocabulary.movingContents
        }
    }

    /// The name field's spoken label, as the Mac's: "Folder name" in New
    /// Folder and "New folder name" in Rename Folder; nil for a sheet with no
    /// name field. Its placeholder is "Folder name" in both, as on the Mac.
    var nameLabel: String? {
        switch task {
        case .newFolder: return PhoneFolderVocabulary.folderName
        case .renameFolder, .newFolderForMove: return PhoneFolderVocabulary.newFolderName
        case .moveFolder, .moveBooks, .deleteFolder: return nil
        }
    }

    /// Where VoiceOver's focus lands as the form arrives: the name field
    /// where there is one, and otherwise the row choosing the folder.
    var arrival: PhoneFolderSheetArrival {
        nameLabel == nil ? .folderRow : .nameField
    }

    /// Whether the name is selected as the field takes the keyboard, so that
    /// typing replaces it, as a Mac text field selects its text when it takes
    /// the keyboard: Rename Folder's, which starts as the folder's name. New
    /// Folder's starts empty.
    var selectsNameOnArrival: Bool {
        if case .renameFolder = task { return true }
        return false
    }

    /// The folder row's visible caption, as the Mac's pop-up's title, or nil
    /// for Rename Folder, which chooses no folder.
    var destinationCaption: String? {
        switch task {
        case .newFolder, .newFolderForMove: return PhoneFolderVocabulary.parentFolder
        case .renameFolder: return nil
        case .moveFolder: return PhoneFolderVocabulary.newParentFolder
        case .moveBooks: return PhoneFolderVocabulary.destination
        case .deleteFolder: return PhoneFolderVocabulary.moveContentsTo
        }
    }

    /// The folder row's spoken label, as the Mac's pop-up's, which also titles
    /// the list of folders it opens; nil for Rename Folder.
    var destinationLabel: String? {
        switch task {
        case .newFolder: return PhoneFolderVocabulary.parentFolder
        case .newFolderForMove: return PhoneFolderVocabulary.parentFolderForNewFolder
        case .renameFolder: return nil
        case .moveFolder: return PhoneFolderVocabulary.destinationParentFolder
        case .moveBooks: return PhoneFolderVocabulary.destinationFolder
        case .deleteFolder: return PhoneFolderVocabulary.destinationForContents
        }
    }

    /// The button that closes the sheet with nothing done: the Mac's "Cancel",
    /// or, in Move to Folder's New Folder..., the Mac's "Cancel New Folder",
    /// named apart from the Move sheet's own Cancel.
    var cancelTitle: String {
        if case .newFolderForMove = task { return LibraryFolderPicker.cancelNewFolderTitle }
        return PhoneFolderVocabulary.cancel
    }

    /// What that button does, where the Mac says it: Cancel New Folder's
    /// "Closes the new folder's fields and keeps the folder chosen."; nil for
    /// a plain Cancel.
    var cancelHint: String? {
        if case .newFolderForMove = task { return LibraryFolderPicker.cancelNewFolderHint }
        return nil
    }

    /// Whether the sheet offers New Folder..., making a folder to move the
    /// books into, as the Mac's Move to Folder does below its folders.
    var offersNewFolder: Bool {
        if case .moveBooks = task { return true }
        return false
    }

    /// The model of Move to Folder's New Folder..., over the same library,
    /// calls, and speech: its folder, once made, becomes the destination
    /// (`PhoneFolderSheetResult.createdFolder`), and it says the Mac's
    /// "Folder Q3 created. Destination folder: Reports/Q3." once it has
    /// closed.
    func newFolderModel() -> PhoneFolderSheetModel {
        PhoneFolderSheetModel(
            task: .newFolderForMove,
            library: library,
            operations: operations,
            announce: announce,
            announceAfterClosing: announceAfterClosing
        )
    }

    /// The words of Delete Folder's question and of Delete Everything, as the
    /// Mac builds them for the folder (`LibraryView.deleteEverythingWording`),
    /// in the mode the Trash preference chooses, which on the phone is always
    /// deleting; nil for the other sheets.
    var deleteWording: FolderRemovalWording? {
        guard case .deleteFolder(let folder) = task else { return nil }
        return FolderRemovalWording(
            mode: library.removalPreferences.deletionMode,
            folderName: folder.name,
            bookCount: library.bookCount(inFolderTree: folder.fullPath),
            feedTitles: library.feedTitles(inside: folder),
            ownFeedTitles: library.feedTitles(of: folder),
            keptBookCount: library.keptBookCount(inFolderTree: folder.fullPath)
        )
    }

    /// The Move Contents screen's title, naming the folder; nil for the
    /// other sheets.
    var moveContentsTitle: String? {
        guard case .deleteFolder(let folder) = task else { return nil }
        return PhoneFolderVocabulary.moveContentsTitle(folderName: folder.name)
    }

    /// What the Move Contents screen is for, naming the folder; nil for the
    /// other sheets.
    var moveContentsExplanation: String? {
        guard case .deleteFolder(let folder) = task else { return nil }
        return PhoneFolderVocabulary.moveContentsExplanation(folderName: folder.name)
    }

    // MARK: Folders Offered

    /// The folders the sheet's folder row offers, "Library Root" first, in the
    /// library's tree order, by the Mac's sheet's rules:
    /// - New Folder: a folder a new one may go in, one above the deepest level.
    /// - Move Folder: the same, less the folder itself and the folders inside
    ///   it, which can't hold it.
    /// - Move to Folder: every folder.
    /// - Delete Folder: every folder but the one deleted and those inside it.
    /// - Rename Folder: none.
    var destinationOptions: [LibraryFolderOption] {
        let folders = library.library
        switch task {
        case .newFolder, .newFolderForMove:
            return LibraryFolderOption.options(in: folders) { $0.depth < BookFolder.maxDepth }
        case .renameFolder:
            return []
        case .moveFolder(let folder):
            let moving = currentPath(of: folder)
            return LibraryFolderOption.options(in: folders) {
                $0.depth < BookFolder.maxDepth && !Self.isFolder($0.fullPath, atOrInside: moving)
            }
        case .moveBooks:
            return LibraryFolderOption.options(in: folders)
        case .deleteFolder(let folder):
            let deleting = currentPath(of: folder)
            return LibraryFolderOption.options(in: folders) { !Self.isFolder($0.fullPath, atOrInside: deleting) }
        }
    }

    /// The folders offered, as the choices of `PhoneChoiceSheet` (the spec,
    /// "Choices"): each by its path, labelled as the Mac's pop-up labels it.
    var destinationChoices: [PhoneChoice<String>] {
        destinationOptions.map { PhoneChoice(id: $0.path, label: $0.label) }
    }

    /// The words the folder row shows and speaks as its value: the chosen
    /// folder's label in the list, "Library Root" for the top level, or the
    /// path itself for one the list doesn't offer.
    var destinationValue: String {
        if let option = destinationOptions.first(where: { $0.path == destination }) {
            return option.label
        }
        return destination.isEmpty ? LibraryFolderOption.rootLabel : destination
    }

    // MARK: Decisions

    /// Whether the confirm button is enabled, by the Mac's sheet's rule, and
    /// never while the work is under way:
    /// - New Folder: a name that can be a folder's.
    /// - Rename Folder: such a name, other than the folder's own.
    /// - Move Folder: a parent other than the folder's own.
    /// - Move to Folder, and Delete Folder's Move Contents: always.
    var canConfirm: Bool {
        guard !isWorking else { return false }
        switch task {
        case .newFolder, .newFolderForMove:
            return BookFolder.normalizedName(name) != nil
        case .renameFolder(let folder):
            guard let typed = BookFolder.normalizedName(name) else { return false }
            return typed != folder.name
        case .moveFolder(let folder):
            return destination != folder.parentPath
        case .moveBooks, .deleteFolder:
            return true
        }
    }

    /// Delete Folder...'s first step, as the Mac takes it: a folder holding
    /// nothing is removed at once, by the library's own call, whose failure
    /// the library's alert explains, and a folder holding anything presents
    /// the Delete Folder sheet. `remove` stands in for the library's call in
    /// a test.
    static func startDeleting(
        _ folder: BookFolder,
        in library: LibraryViewModel,
        removingEmptyWith remove: (@MainActor (BookFolder) -> Void)? = nil
    ) -> PhoneFolderDeleteStart {
        guard library.folderHasContents(folder) else {
            if let remove {
                remove(folder)
            } else {
                library.removeFolder(folder)
            }
            return .removedAtOnce
        }
        return .asks
    }

    // MARK: Doing the Work

    /// Does the sheet's work, once: makes, renames, or moves the folder,
    /// moves the books, or moves Delete Folder's contents out and deletes it.
    ///
    /// After a success it schedules the sentence said once the sheet has
    /// closed, if there is one, and returns what was done, for the sheet to
    /// close with. After a failure it keeps the reason, says it once, and
    /// returns nil, so the sheet stays open with what was typed and chosen.
    /// It does nothing, returning nil, while the confirm button is dimmed.
    func confirm() async -> PhoneFolderSheetResult? {
        guard canConfirm else { return nil }
        // The last failure was about the attempt before.
        failureMessage = nil
        isWorking = true
        let (outcome, result) = await perform()
        isWorking = false
        if let failure = outcome.failureMessage {
            failureMessage = failure
            announce(failure)
            return nil
        }
        if let sentence = sentenceAfter(outcome) {
            announceAfterClosing(sentence)
        }
        return result
    }

    /// Delete Folder's Delete Everything, once its confirmation is answered:
    /// deletes the folder and everything in it. Returns what was done when the
    /// folder is gone, and nil when it isn't, as when a file couldn't be
    /// deleted and the library's alert says so; the sheet closes either way,
    /// as the Mac's question does. Nothing for the other sheets.
    func deleteEverything() -> PhoneFolderSheetResult? {
        guard case .deleteFolder(let folder) = task, !isWorking else { return nil }
        operations.removeFolderAndEverything(folder)
        let isGone = !library.library.folders.contains { $0.id == folder.id }
        return isGone ? .deletedFolder(id: folder.id, contentsMovedTo: nil) : nil
    }

    /// Makes the library call for the sheet, and what it did should it work.
    private func perform() async -> (OperationOutcome, PhoneFolderSheetResult) {
        switch task {
        case .newFolder, .newFolderForMove:
            let made = BookFolder.normalizedName(name) ?? name
            return (operations.createFolder(name, destination), .createdFolder(path: createdPath(named: made)))
        case .renameFolder(let folder):
            let outcome = await operations.renameFolder(folder, name)
            return (outcome, .renamedFolder(id: folder.id, path: currentPath(of: folder)))
        case .moveFolder(let folder):
            let outcome = await operations.moveFolder(folder, destination)
            return (outcome, .movedFolder(id: folder.id, path: currentPath(of: folder)))
        case .moveBooks(let books):
            let outcome = await operations.moveBooks(books, destination)
            // A feed's item never moves (FR11); the phone has no feeds yet.
            let moved = books.filter { !$0.isFeedItem }.map(\.id)
            return (outcome, .movedBooks(ids: moved, path: destination))
        case .deleteFolder(let folder):
            let outcome = await operations.removeFolderMovingContents(folder, destination)
            return (outcome, .deletedFolder(id: folder.id, contentsMovedTo: destination))
        }
    }

    /// The sentence said once the sheet has closed after `outcome`, as the
    /// Mac says it: New Folder's "Folder Q3 created in Reports.", Move to
    /// Folder's New Folder...'s "Folder Q3 created. Destination folder:
    /// Reports/Q3.", and what Move to Folder left where it was, if anything.
    /// The other sheets say nothing on the Mac, where the list shows the
    /// change.
    private func sentenceAfter(_ outcome: OperationOutcome) -> String? {
        switch task {
        case .newFolder:
            guard let made = BookFolder.normalizedName(name) else { return nil }
            return NewFolderSheet.createdAnnouncement(name: made, parentPath: destination)
        case .newFolderForMove:
            guard let made = BookFolder.normalizedName(name) else { return nil }
            return LibraryFolderPicker.newFolderCreatedAnnouncement(
                name: made,
                pickerLabel: PhoneFolderVocabulary.destinationFolder,
                chosen: createdPath(named: made)
            )
        case .moveBooks:
            return outcome.message
        case .renameFolder, .moveFolder, .deleteFolder:
            return nil
        }
    }

    // MARK: Helpers

    /// The path of the folder New Folder makes, named `made` as the library
    /// stores the name, in the folder chosen: worked out as the Mac's folder
    /// picker works it out.
    private func createdPath(named made: String) -> String {
        destination.isEmpty ? made : "\(destination)/\(made)"
    }

    /// The path the library gives `folder` now, which an edit may have
    /// changed since the sheet opened; the sheet's copy's when it's gone.
    private func currentPath(of folder: BookFolder) -> String {
        library.library.folders.first { $0.id == folder.id }?.fullPath ?? folder.fullPath
    }

    /// Whether the folder at `path` is the folder at `other`, or inside it.
    private nonisolated static func isFolder(_ path: String, atOrInside other: String) -> Bool {
        path == other || path.hasPrefix(other + "/")
    }

    /// The name a sheet starts with: Rename Folder's folder's own, so a small
    /// change needs no retyping, as on the Mac; nothing for the others.
    private static func initialName(for task: PhoneFolderSheetTask) -> String {
        if case .renameFolder(let folder) = task { return folder.name }
        return ""
    }

    /// The folder a sheet starts with chosen, as the Mac's sheets choose it:
    /// - New Folder: the folder the Library shows.
    /// - Move Folder, and Delete Folder's Move Contents: the folder's parent.
    /// - Move to Folder: the folder books were last moved to, while it's still
    ///   in the library, or else the top level.
    private static func initialDestination(for task: PhoneFolderSheetTask, in library: LibraryViewModel) -> String {
        switch task {
        case .newFolder(let parentPath):
            return parentPath
        case .renameFolder, .newFolderForMove:
            return ""
        case .moveFolder(let folder), .deleteFolder(let folder):
            return folder.parentPath
        case .moveBooks:
            let last = library.lastMovedFolderPath
            let offered = LibraryFolderOption.options(in: library.library).contains { $0.path == last }
            return offered ? last : ""
        }
    }

}
