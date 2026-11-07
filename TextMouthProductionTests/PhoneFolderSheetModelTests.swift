import XCTest
@testable import TextMouth

/// `PhoneFolderSheetModel`: what each of the iPhone's folder sheets decides,
/// by the Mac's sheets' rules. Every library call is a stand-in the test hands
/// in, and the library is held in memory, so no test touches a disk; what the
/// sheets say is captured, so nothing is spoken.
@MainActor
final class PhoneFolderSheetModelTests: XCTestCase {
    // MARK: - New Folder

    /// New Folder offers the top level and every folder a new one may go in,
    /// in tree order: not a folder at the deepest level, as on the Mac.
    func testNewFolderOffersTheFoldersANewOneMayGoIn() {
        let library = Self.library(folders: ["A", "A/B", "A/B/C", "A/B/C/D", "E"])
        let model = PhoneFolderSheetModel(task: .newFolder(parentPath: ""), library: library)

        XCTAssertEqual(model.destinationOptions.map(\.path), ["", "A", "A/B", "A/B/C", "E"])
        XCTAssertEqual(model.destinationOptions.first?.label, LibraryFolderOption.rootLabel)
    }

    /// New Folder starts in the folder the Library shows, and its row says
    /// that folder, or Library Root at the top.
    func testNewFolderStartsInTheFolderShown() {
        let library = Self.library(folders: ["Reports"])

        let inReports = PhoneFolderSheetModel(task: .newFolder(parentPath: "Reports"), library: library)
        XCTAssertEqual(inReports.destination, "Reports")
        XCTAssertEqual(inReports.destinationValue, "Reports")

        let atTop = PhoneFolderSheetModel(task: .newFolder(parentPath: ""), library: library)
        XCTAssertEqual(atTop.destination, "")
        XCTAssertEqual(atTop.destinationValue, "Library Root")
        XCTAssertEqual(atTop.name, "")
    }

    /// Create is enabled only for a name a folder can have.
    func testCreateIsEnabledOnlyForANameAFolderCanHave() {
        let model = PhoneFolderSheetModel(task: .newFolder(parentPath: ""), library: Self.library(folders: []))

        for refused in ["", "   ", ".", "..", "Notes.tmb"] {
            model.name = refused
            XCTAssertFalse(model.canConfirm, refused)
        }
        model.name = "Q3"
        XCTAssertTrue(model.canConfirm)
    }

    /// Create makes the folder through the library's call, with the name as
    /// typed, and the sheet closes with the new folder's path; once it has
    /// closed, VoiceOver hears the Mac's "Folder Q3 created in Reports.".
    func testCreateMakesTheFolderAndSaysSoOnceClosed() async {
        let speech = Speech()
        let made = Recorder()
        var operations = Self.unusedOperations()
        operations.createFolder = { name, parent in
            made.items.append("\(parent)|\(name)")
            return .success(nil)
        }
        let model = speech.model(.newFolder(parentPath: "Reports"), Self.library(folders: ["Reports"]), operations)
        model.name = " Q3 "

        let result = await model.confirm()

        XCTAssertEqual(result, .createdFolder(path: "Reports/Q3"))
        XCTAssertEqual(made.items, ["Reports| Q3 "], "the name goes to the library as typed, which trims it")
        XCTAssertEqual(speech.afterClosing, ["Folder Q3 created in Reports."])
        XCTAssertEqual(speech.atOnce, [])
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isWorking)
    }

    /// A folder made at the top level is said to be in Library Root.
    func testAFolderMadeAtTheTopIsSaidToBeInLibraryRoot() async {
        let speech = Speech()
        var operations = Self.unusedOperations()
        operations.createFolder = { _, _ in .success(nil) }
        let model = speech.model(.newFolder(parentPath: ""), Self.library(folders: []), operations)
        model.name = "Q3"

        let result = await model.confirm()

        XCTAssertEqual(result, .createdFolder(path: "Q3"))
        XCTAssertEqual(speech.afterClosing, ["Folder Q3 created in Library Root."])
    }

    /// A refused folder keeps the sheet open with the reason, said once at
    /// once and nothing said after; changing the name or the parent clears
    /// the reason, and setting either to what it already was doesn't.
    func testARefusedFolderKeepsTheSheetOpenWithTheReason() async {
        let speech = Speech()
        let reason = "Could not create folder: A folder named \"Q3\" already exists in Library Root."
        var operations = Self.unusedOperations()
        operations.createFolder = { _, _ in .failure(reason) }
        let model = speech.model(.newFolder(parentPath: ""), Self.library(folders: ["Q3", "Reports"]), operations)
        model.name = "Q3"

        let result = await model.confirm()

        XCTAssertNil(result)
        XCTAssertEqual(model.failureMessage, reason)
        XCTAssertEqual(speech.atOnce, [reason])
        XCTAssertEqual(speech.afterClosing, [])
        XCTAssertFalse(model.isWorking)

        model.name = "Q3"
        XCTAssertEqual(model.failureMessage, reason, "the same name is no change")
        model.name = "Q4"
        XCTAssertNil(model.failureMessage)

        _ = await model.confirm()
        XCTAssertEqual(model.failureMessage, reason)
        model.destination = "Reports"
        XCTAssertNil(model.failureMessage)
    }

    // MARK: - Rename Folder

    /// Rename Folder starts with the folder's own name, and Rename is enabled
    /// only for another name a folder can have: a change of case counts.
    func testRenameStartsWithTheFolderNameAndNeedsAnother() {
        let library = Self.library(folders: ["Fiction"])
        let folder = Self.folder("Fiction", in: library)
        let model = PhoneFolderSheetModel(task: .renameFolder(folder), library: library)

        XCTAssertEqual(model.name, "Fiction")
        XCTAssertFalse(model.canConfirm)
        model.name = "Fiction  "
        XCTAssertFalse(model.canConfirm, "the spaces Rename trims are no change")
        model.name = ""
        XCTAssertFalse(model.canConfirm)
        model.name = "fiction"
        XCTAssertTrue(model.canConfirm)
        model.name = "Novels"
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(model.destinationOptions.map(\.path), [], "Rename chooses no folder")
        XCTAssertNil(model.destinationLabel)
    }

    /// Rename renames through the library's call and closes with the folder
    /// at its new path, saying nothing after, as on the Mac.
    func testRenameClosesWithTheFolderAtItsNewPath() async {
        let speech = Speech()
        let library = Self.library(folders: ["Fiction"])
        let folder = Self.folder("Fiction", in: library)
        var operations = Self.unusedOperations()
        operations.renameFolder = { renamed, name in
            Self.rename(renamed, to: name, in: library)
            return .success(nil)
        }
        let model = speech.model(.renameFolder(folder), library, operations)
        model.name = "Novels"

        let result = await model.confirm()

        XCTAssertEqual(result, .renamedFolder(id: folder.id, path: "Novels"))
        XCTAssertEqual(speech.afterClosing, [])
        XCTAssertEqual(speech.atOnce, [])
    }

    /// While the work is under way, the sheet's buttons are dimmed, so it
    /// can't start twice, and its work says the Mac's words.
    func testTheWorkCannotStartTwice() async {
        let speech = Speech()
        let library = Self.library(folders: ["Fiction"])
        let folder = Self.folder("Fiction", in: library)
        let probe = Probe()
        var operations = Self.unusedOperations()
        operations.renameFolder = { _, _ in
            probe.sawWorking = probe.model?.isWorking
            probe.sawEnabled = probe.model?.canConfirm
            probe.secondTry = await probe.model?.confirm()
            probe.triedSecond = true
            return .success(nil)
        }
        let model = speech.model(.renameFolder(folder), library, operations)
        probe.model = model
        model.name = "Novels"

        _ = await model.confirm()

        XCTAssertEqual(probe.sawWorking, true)
        XCTAssertEqual(probe.sawEnabled, false)
        XCTAssertTrue(probe.triedSecond)
        XCTAssertNil(probe.secondTry, "a second Rename while the first works does nothing")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.workLabel, "Renaming the folder...")
    }

    // MARK: - Move Folder

    /// Move Folder offers the top level and every folder that can hold it,
    /// by the Mac's rule: not the folder itself, not one inside it, and not
    /// one at the deepest level.
    func testMoveFolderOffersNeitherItselfNorWhatIsInsideIt() {
        let library = Self.library(folders: ["A", "A/B", "A/B/C", "A/B2", "D", "D/E", "D/E/F", "D/E/F/G"])
        let folder = Self.folder("A/B", in: library)
        let model = PhoneFolderSheetModel(task: .moveFolder(folder), library: library)

        // A/B2 shares the moved folder's first letters, and stays offered.
        XCTAssertEqual(model.destinationOptions.map(\.path), ["", "A", "A/B2", "D", "D/E", "D/E/F"])
    }

    /// Move Folder starts at the folder's parent, and Move is enabled only
    /// for another parent.
    func testMoveFolderStartsAtItsParentAndNeedsAnother() {
        let library = Self.library(folders: ["A", "A/B", "D"])
        let model = PhoneFolderSheetModel(task: .moveFolder(Self.folder("A/B", in: library)), library: library)

        XCTAssertEqual(model.destination, "A")
        XCTAssertFalse(model.canConfirm)
        model.destination = ""
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(model.title, "Move \"B\"")
        XCTAssertEqual(model.destinationLabel, "Destination parent folder")
        XCTAssertEqual(model.destinationCaption, "New parent folder")
    }

    /// A move that works closes with the folder at its new path.
    func testMoveFolderClosesWithTheFolderAtItsNewPath() async {
        let library = Self.library(folders: ["A", "A/B", "D"])
        let folder = Self.folder("A/B", in: library)
        var operations = Self.unusedOperations()
        operations.moveFolder = { moved, parent in
            Self.move(moved, under: parent, in: library)
            return .success(nil)
        }
        let model = Speech().model(.moveFolder(folder), library, operations)
        model.destination = "D"

        let result = await model.confirm()

        XCTAssertEqual(result, .movedFolder(id: folder.id, path: "D/B"))
    }

    // MARK: - Move to Folder

    /// Move to Folder offers every folder, and starts at the folder books were
    /// last moved to while it's still in the library, else the top level.
    func testMoveToFolderStartsAtTheLastFolderMovedToWhileItIsThere() {
        let library = Self.library(folders: ["A", "D"])
        let book = Self.book("Dune", in: "")

        library.lastMovedFolderPath = "D"
        let toLast = PhoneFolderSheetModel(task: .moveBooks([book]), library: library)
        XCTAssertEqual(toLast.destination, "D")
        XCTAssertEqual(toLast.destinationOptions.map(\.path), ["", "A", "D"])

        library.lastMovedFolderPath = "Gone"
        let toTop = PhoneFolderSheetModel(task: .moveBooks([book]), library: library)
        XCTAssertEqual(toTop.destination, "")
        XCTAssertTrue(toTop.canConfirm, "Move is always enabled, as on the Mac")
    }

    /// Move to Folder's title names one book or counts several, and its work
    /// counts the books.
    func testMoveToFolderNamesOneBookOrCountsSeveral() {
        let library = Self.library(folders: [])
        let one = PhoneFolderSheetModel(task: .moveBooks([Self.book("Dune", in: "")]), library: library)
        XCTAssertEqual(one.title, "Move \"Dune\"")
        XCTAssertEqual(one.workLabel, "Moving 1 book...")

        let three = PhoneFolderSheetModel(
            task: .moveBooks([Self.book("Dune", in: ""), Self.book("Emma", in: ""), Self.book("Kim", in: "")]),
            library: library
        )
        XCTAssertEqual(three.title, "Move 3 Books")
        XCTAssertEqual(three.workLabel, "Moving 3 books...")
        XCTAssertEqual(three.confirmTitle, "Move")
        XCTAssertEqual(three.destinationLabel, "Destination folder")
    }

    /// The books move through the library's call to the folder chosen, and
    /// what the move left where it was, if anything, is said once the sheet
    /// has closed.
    func testMoveToFolderMovesTheBooksAndSaysWhatTheMoveLeft() async {
        let library = Self.library(folders: ["D"])
        let books = [Self.book("Dune", in: ""), Self.book("Emma", in: "")]
        let moved = Recorder()
        var operations = Self.unusedOperations()
        operations.moveBooks = { books, path in
            moved.items = books.map(\.title) + [path]
            return .success("Left where it was: “Episode 4”.")
        }
        let speech = Speech()
        let model = speech.model(.moveBooks(books), library, operations)
        model.destination = "D"

        let result = await model.confirm()

        XCTAssertEqual(result, .movedBooks(ids: books.map(\.id), path: "D"))
        XCTAssertEqual(moved.items, ["Dune", "Emma", "D"])
        XCTAssertEqual(speech.afterClosing, ["Left where it was: “Episode 4”."])

        var silent = Self.unusedOperations()
        silent.moveBooks = { _, _ in .success(nil) }
        let quiet = Speech()
        _ = await quiet.model(.moveBooks(books), library, silent).confirm()
        XCTAssertEqual(quiet.afterClosing, [], "a move that left nothing says nothing")
    }

    // MARK: - Delete Folder

    /// Delete Folder's first step is the Mac's: a folder holding nothing is
    /// removed at once, with no question, and one holding a book or a
    /// subfolder asks.
    func testStartDeletingRemovesAnEmptyFolderAtOnceAndAsksForOneHoldingSomething() {
        let library = Self.library(folders: ["Empty", "Shelf", "Parent", "Parent/Child"])
        library.library.books = [Self.book("Dune", in: "Shelf")]
        let removed = Recorder()
        let remove: @MainActor (BookFolder) -> Void = { removed.items.append($0.fullPath) }

        let starts: [(String, PhoneFolderDeleteStart)] = [("Empty", .removedAtOnce), ("Shelf", .asks), ("Parent", .asks)]
        for (path, start) in starts {
            let folder = Self.folder(path, in: library)
            XCTAssertEqual(PhoneFolderSheetModel.startDeleting(folder, in: library, removingEmptyWith: remove), start, path)
        }
        XCTAssertEqual(removed.items, ["Empty"])
    }

    /// Delete Folder's question names the folder and counts the books in it
    /// and below it, in the Mac's words.
    func testDeleteFolderAsksInTheMacsWords() throws {
        let library = Self.library(folders: ["A", "A/B"])
        library.library.books = [Self.book("Dune", in: "A"), Self.book("Emma", in: "A/B"), Self.book("Kim", in: "")]
        let model = PhoneFolderSheetModel(task: .deleteFolder(Self.folder("A", in: library)), library: library)

        let wording = try XCTUnwrap(model.deleteWording)
        XCTAssertEqual(wording.folderName, "A")
        XCTAssertEqual(wording.bookCount, 2)
        XCTAssertTrue(wording.choiceMessage.hasPrefix("“A” contains 2 books and may have subfolders."))
        XCTAssertEqual(model.title, "Delete Folder?")
        XCTAssertEqual(model.moveContentsTitle, "Move Contents of \"A\"")
        XCTAssertEqual(model.moveContentsExplanation, "Choose where to move the books and subfolders before deleting \"A\".")
        XCTAssertEqual(model.confirmTitle, "Move Contents & Delete Folder")
        XCTAssertEqual(model.destinationLabel, "Destination for folder contents")
        XCTAssertEqual(model.destinationCaption, "Move contents to")
        XCTAssertEqual(model.workLabel, "Moving the folder's contents...")
    }

    /// Move Contents offers every folder but the one deleted and those inside
    /// it, at any depth, and starts at the folder's parent.
    func testMoveContentsOffersEveryFolderButItselfAndWhatIsInsideIt() {
        let library = Self.library(folders: ["A", "A/B", "A/B/C", "A/B2", "D", "D/E", "D/E/F", "D/E/F/G"])
        let model = PhoneFolderSheetModel(task: .deleteFolder(Self.folder("A/B", in: library)), library: library)

        XCTAssertEqual(model.destinationOptions.map(\.path), ["", "A", "A/B2", "D", "D/E", "D/E/F", "D/E/F/G"])
        XCTAssertEqual(model.destination, "A")
        XCTAssertTrue(model.canConfirm)
    }

    /// Move Contents & Delete Folder moves the contents to the folder chosen
    /// through the library's call, then closes with the folder gone.
    func testMoveContentsClosesWithTheFolderGone() async {
        let library = Self.library(folders: ["A", "D"])
        let folder = Self.folder("A", in: library)
        let asked = Recorder()
        var operations = Self.unusedOperations()
        operations.removeFolderMovingContents = { removed, path in
            asked.items.append("\(removed.fullPath)>\(path)")
            return .success(nil)
        }
        let model = Speech().model(.deleteFolder(folder), library, operations)
        model.destination = "D"

        let result = await model.confirm()

        XCTAssertEqual(result, .deletedFolder(id: folder.id, contentsMovedTo: "D"))
        XCTAssertEqual(asked.items, ["A>D"])
    }

    /// Delete Everything closes with the folder gone only when it is: a folder
    /// the library couldn't delete, whose reason its alert gives, reports
    /// nothing.
    func testDeleteEverythingReportsOnlyAFolderThatIsGone() {
        let library = Self.library(folders: ["A", "D"])
        let folder = Self.folder("A", in: library)

        var deleting = Self.unusedOperations()
        deleting.removeFolderAndEverything = { removed in
            library.library.folders.removeAll { $0.id == removed.id }
        }
        let deleted = PhoneFolderSheetModel(task: .deleteFolder(folder), library: library, operations: deleting)
        XCTAssertEqual(deleted.deleteEverything(), .deletedFolder(id: folder.id, contentsMovedTo: nil))

        let other = Self.folder("D", in: library)
        var failing = Self.unusedOperations()
        failing.removeFolderAndEverything = { _ in }
        let kept = PhoneFolderSheetModel(task: .deleteFolder(other), library: library, operations: failing)
        XCTAssertNil(kept.deleteEverything())

        let notDelete = PhoneFolderSheetModel(task: .renameFolder(other), library: library, operations: failing)
        XCTAssertNil(notDelete.deleteEverything(), "only Delete Folder deletes everything")
    }

    // MARK: - The Folder Row

    /// The folder row says the folder chosen as the list labels it, Library
    /// Root for the top level, and a path the list doesn't offer as it is.
    func testTheFolderRowSaysTheFolderChosen() {
        let library = Self.library(folders: ["A", "A/B"])
        let model = PhoneFolderSheetModel(task: .moveBooks([Self.book("Dune", in: "")]), library: library)

        model.destination = ""
        XCTAssertEqual(model.destinationValue, "Library Root")
        model.destination = "A/B"
        XCTAssertEqual(model.destinationValue, "A/B")
        model.destination = "Elsewhere"
        XCTAssertEqual(model.destinationValue, "Elsewhere")
    }

    // MARK: - Fixtures

    /// What a library call stand-in was asked, in order.
    @MainActor
    private final class Recorder {
        /// Each request, oldest first.
        var items: [String] = []
    }

    /// What a sheet said, at once and once closed, in order.
    @MainActor
    private final class Speech {
        /// Said at once: failures.
        var atOnce: [String] = []
        /// Said once the sheet has closed.
        var afterClosing: [String] = []

        /// A model for `task` over `library` with `operations`, speaking here.
        func model(
            _ task: PhoneFolderSheetTask,
            _ library: LibraryViewModel,
            _ operations: PhoneFolderOperations
        ) -> PhoneFolderSheetModel {
            PhoneFolderSheetModel(
                task: task,
                library: library,
                operations: operations,
                announce: { [unowned self] in atOnce.append($0) },
                announceAfterClosing: { [unowned self] in afterClosing.append($0) }
            )
        }
    }

    /// What the model looked like while its work was under way.
    @MainActor
    private final class Probe {
        /// The model being probed.
        weak var model: PhoneFolderSheetModel?
        /// Whether it said it was working.
        var sawWorking: Bool?
        /// Whether its confirm button was enabled.
        var sawEnabled: Bool?
        /// Whether a second confirm was made meanwhile.
        var triedSecond = false
        /// What that second confirm returned.
        var secondTry: PhoneFolderSheetResult?
    }

    /// Library calls that fail the test if made: each test replaces the ones
    /// it expects.
    private static func unusedOperations() -> PhoneFolderOperations {
        PhoneFolderOperations(
            createFolder: { _, _ in XCTFail("createFolder"); return .failure("unused") },
            renameFolder: { _, _ in XCTFail("renameFolder"); return .failure("unused") },
            moveFolder: { _, _ in XCTFail("moveFolder"); return .failure("unused") },
            moveBooks: { _, _ in XCTFail("moveBooks"); return .failure("unused") },
            removeFolderMovingContents: { _, _ in XCTFail("removeFolderMovingContents"); return .failure("unused") },
            removeFolderAndEverything: { _ in XCTFail("removeFolderAndEverything") }
        )
    }

    /// An inert library model holding, in memory only, the folders at `paths`,
    /// each given parents first.
    private static func library(folders paths: [String]) -> LibraryViewModel {
        let viewModel = LibraryViewModel(initializeServices: false)
        var library = Library()
        library.folders = paths.map { path in
            let parts = path.components(separatedBy: "/")
            return BookFolder(name: parts[parts.count - 1], parentPath: parts.dropLast().joined(separator: "/"))
        }
        viewModel.library = library
        return viewModel
    }

    /// The folder at `path` in `library`; a stand-in when it isn't there, so
    /// the test fails on what it checks rather than here.
    private static func folder(_ path: String, in library: LibraryViewModel) -> BookFolder {
        let found = library.library.folders.first { $0.fullPath == path }
        XCTAssertNotNil(found, path)
        return found ?? BookFolder(name: path)
    }

    /// A book titled `title` in the folder at `path`, with no file.
    private static func book(_ title: String, in path: String) -> Book {
        Book(title: title, format: .txt, filePath: "/nonexistent/\(title).txt", md5Hash: "phone-\(UUID().uuidString)", folderPath: path)
    }

    /// Renames `folder` to `name` in memory, as the library's call would.
    private static func rename(_ folder: BookFolder, to name: String, in library: LibraryViewModel) {
        guard let index = library.library.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        library.library.folders[index].name = name
    }

    /// Moves `folder` under `parent` in memory, as the library's call would.
    private static func move(_ folder: BookFolder, under parent: String, in library: LibraryViewModel) {
        guard let index = library.library.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        library.library.folders[index].parentPath = parent
    }
}
