import XCTest
@testable import TextMouth

/// A folder chosen for the library in Storage settings is assessed before
/// anything is done there (FR02): missing or empty folders can receive the
/// library, folders holding a library can be used as they are, the folder in
/// use is said to be that, and anything else is refused, saying why. Where
/// the folder lives comes from the cloud services, here a fake one, and the
/// confirmation says what that means.
final class StorageDestinationAssessmentTests: XCTestCase {

    // MARK: - The Matrix

    /// Each kind of folder gets its verdict in each kind of location: the
    /// location changes what the words say, never what can be done.
    func testEveryKindOfFolderInEveryKindOfLocation() throws {
        let world = try makeWorld()
        let locations: [StorageLocation] = [.local, .cloud(.iCloudDrive), .otherVolume(name: "Backup")]
        let size = try DataDirectoryCopyPlan(of: world.current).totalBytes
        XCTAssertGreaterThan(size, 0)
        let markedIdentity = try XCTUnwrap(LibraryIdentity.read(in: world.marked))

        for location in locations {
            let cases: [(folder: URL, verdict: StorageDestinationAssessment.Verdict, size: Int64?)] = [
                (world.missing, .moveHere, size),
                (world.empty, .moveHere, size),
                (world.marked, .useLibrary(.init(identity: markedIdentity, isCopyOfCurrentLibrary: false)), nil),
                (world.indexed, .useLibrary(.init(identity: nil, isCopyOfCurrentLibrary: false)), nil),
                (world.current, .currentLibrary, nil),
                (world.other, .refused(.otherItems([".hidden", "notes.txt", "photos"])), nil),
            ]
            for expected in cases {
                world.provider.setLocation(location, of: expected.folder)

                let assessment = world.assess(expected.folder)

                let label = "\(expected.folder.lastPathComponent) in \(location)"
                XCTAssertEqual(assessment.verdict, expected.verdict, label)
                XCTAssertEqual(assessment.location, location, label)
                XCTAssertEqual(assessment.folder, expected.folder, label)
                XCTAssertEqual(assessment.librarySize, expected.size, label)
            }
        }
    }

    /// The move's confirmation says what the location means: today's words
    /// for this Mac's disk, the drive to keep connected for another volume,
    /// and the upload, with the library's size, for a cloud folder.
    func testTheMoveConfirmationSaysWhatTheLocationMeans() throws {
        let world = try makeWorld()
        let size = try DataDirectoryCopyPlan(of: world.current).totalBytes
        let path = world.empty.path
        let today = "Copy all TextMouth data to \(path), validate it, and use the new location? "
            + "The current directory will be retained as recovery data."
        let expectations: [(StorageLocation, String)] = [
            (.local, today),
            (.otherVolume(name: "Backup"), today + " TextMouth needs the drive “Backup” connected to open the library."),
            (
                .cloud(.iCloudDrive),
                today + " Your library (\(StorageWording.size(size))) will upload to iCloud Drive in the background. "
                    + "Books stay on this Mac until you remove their downloads or macOS needs space. A book that's only "
                    + "in the cloud needs an internet connection to open."
            ),
        ]

        for (location, message) in expectations {
            world.provider.setLocation(location, of: world.empty)

            let choice = StorageChoice(for: world.assess(world.empty), current: world.summary)

            XCTAssertEqual(
                choice,
                .confirm(title: "Move Library Here?", message: message, button: "Move Library Here", action: .move(to: world.empty)),
                "\(location)"
            )
        }
    }

    /// Use This Library's confirmation names both libraries, the one in use
    /// with its books, and says what the chosen one's location means.
    func testUseThisLibraryNamesBothLibraries() throws {
        let world = try makeWorld()
        world.provider.setLocation(.cloud(.dropbox), of: world.marked)

        let choice = StorageChoice(for: world.assess(world.marked), current: world.summary)

        XCTAssertEqual(choice, .confirm(
            title: "Use This Library?",
            message: "TextMouth will stop using the library in \(world.current.path) (3 books) and open the library in "
                + "\(world.marked.path) instead. Nothing is copied, and the library in \(world.current.path) stays as it "
                + "is. TextMouth will quit and open again to load it. A book that's only in Dropbox needs an internet "
                + "connection to open.",
            button: "Use This Library",
            action: .useLibrary(at: world.marked)
        ))
    }

    /// A folder holding another copy of the library in use, by its identity,
    /// such as the folder an earlier move left behind, can be used, and the
    /// confirmation says it may not have the latest changes.
    func testAnotherCopyOfTheLibraryInUseIsSaidToBeOne() throws {
        let world = try makeWorld()
        let copy = world.base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: world.current, to: copy)

        let assessment = world.assess(copy)

        XCTAssertEqual(
            assessment.verdict,
            .useLibrary(.init(identity: try LibraryIdentity.read(in: world.current), isCopyOfCurrentLibrary: true))
        )
        guard case .confirm(_, let message, _, _) = StorageChoice(for: assessment, current: world.summary) else {
            return XCTFail("Expected a confirmation")
        }
        XCTAssertTrue(message.contains(StorageWording.copyOfCurrentLibrarySentence), message)
    }

    /// The folder in use, under its own name or through a link to it, is
    /// said to be the library TextMouth is using; nothing is offered.
    func testTheFolderInUseIsSaidToBeTheLibraryInUse() throws {
        let world = try makeWorld()
        let link = world.base.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: world.current)

        XCTAssertEqual(world.assess(link).verdict, .currentLibrary)
        XCTAssertEqual(
            StorageChoice(for: world.assess(world.current), current: world.summary),
            .report("This is the library TextMouth is using: \(world.current.path).", isRefusal: false)
        )
    }

    // MARK: - Refusals

    /// A file, a folder in the Trash, and a folder inside the library in use
    /// are refused, each saying why.
    func testAFileTheTrashAndAFolderInsideTheLibraryAreRefused() throws {
        let world = try makeWorld()
        let file = world.base.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let trashed = world.base.appendingPathComponent(".Trash/Old Library", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let inside = world.current.appendingPathComponent("Library/Spare", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        XCTAssertEqual(world.assess(file).verdict, .refused(.notAFolder))
        XCTAssertEqual(world.report(file), "There is a file at \(file.path), not a folder. Choose a folder.")
        XCTAssertEqual(world.assess(trashed).verdict, .refused(.inTrash))
        XCTAssertEqual(world.report(trashed), "The folder \(trashed.path) is in the Trash. Choose a folder outside it.")
        guard case .refused(.overlap(.destinationInsideSource, let explanation)) = world.assess(inside).verdict else {
            return XCTFail("A folder inside the library in use was not refused as one")
        }
        XCTAssertEqual(world.report(inside), explanation)
        XCTAssertTrue(explanation.contains(world.current.path), explanation)
    }

    /// The other items in a folder are counted and named, at most three
    /// then how many more, and the refusal says what can be chosen instead.
    func testOtherItemsAreCountedAndNamed() throws {
        let world = try makeWorld()

        XCTAssertEqual(
            world.report(world.other),
            "The folder \(world.other.path) holds 3 other items: .hidden, notes.txt, and photos. "
                + "Choose an empty folder, or one that holds a TextMouth library."
        )
        let one = world.base.appendingPathComponent("One", isDirectory: true)
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try Data().write(to: one.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(
            world.report(one),
            "The folder \(one.path) holds 1 other item: .DS_Store. Choose an empty folder, or one that holds a TextMouth library."
        )
    }

    /// A folder TextMouth can't read, and one whose listing is only in the
    /// cloud, are refused without anything being read or downloaded.
    func testUnreadableAndNotDownloadedFoldersAreRefused() throws {
        let world = try makeWorld()
        let locked = world.base.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try setPermissions(0o000, of: locked)

        XCTAssertEqual(world.assess(locked).verdict, .refused(.unreadable("permission denied")))
        XCTAssertEqual(world.report(locked), "TextMouth can't read the folder \(locked.path): permission denied.")

        var probes = world.probes
        probes.listFolder = { _ in throw POSIXError(.EDEADLK) }
        world.provider.setLocation(.cloud(.googleDrive), of: world.empty)
        let assessment = StorageDestinationAssessment.assess(world.empty, context: world.context, probes: probes)
        XCTAssertEqual(assessment.verdict, .refused(.notDownloaded))
        XCTAssertEqual(
            StorageChoice(for: assessment, current: world.summary),
            .report(
                "The folder \(world.empty.path) is in Google Drive and isn't on this Mac yet. "
                    + "Open it in Finder to download it, then choose it again.",
                isRefusal: true
            )
        )
    }

    /// A move needs the folder that would hold the copy to be there and
    /// writable; a library to be used needs its own folder writable.
    func testMovesAndLibrariesNeedFoldersTextMouthCanChange() throws {
        let world = try makeWorld()
        let orphan = world.base.appendingPathComponent("Nowhere/Library Home", isDirectory: true)
        XCTAssertEqual(world.assess(orphan).verdict, .refused(.parentMissing))
        XCTAssertEqual(
            world.report(orphan),
            "\(orphan.path) can't be made, because the folder that would hold it, "
                + "\(orphan.deletingLastPathComponent().path), can't be found."
        )

        let readOnly = world.base.appendingPathComponent("ReadOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let inside = readOnly.appendingPathComponent("Library Home", isDirectory: true)
        try setPermissions(0o555, of: readOnly)
        XCTAssertEqual(world.assess(inside).verdict, .refused(.notWritable(readOnly.path)))
        XCTAssertEqual(
            world.report(inside),
            "TextMouth isn't allowed to make changes in \(readOnly.path). Choose another folder."
        )

        try setPermissions(0o555, of: world.indexed)
        XCTAssertEqual(world.assess(world.indexed).verdict, .refused(.notWritable(world.indexed.path)))
    }

    /// A move to another volume with less free space than the library needs
    /// is refused, naming both sizes; on one volume, where the copy clones
    /// its files, the free space is not counted.
    func testAMoveNeedsRoomOnlyOnAnotherVolume() throws {
        let world = try makeWorld()
        let size = try DataDirectoryCopyPlan(of: world.current).totalBytes
        var probes = world.probes
        probes.availableCapacity = { _ in 10 }

        probes.areOnOneVolume = { _, _ in false }
        let elsewhere = StorageDestinationAssessment.assess(world.empty, context: world.context, probes: probes)
        XCTAssertEqual(elsewhere.verdict, .refused(.notEnoughSpace(needed: size, available: 10)))
        XCTAssertEqual(
            StorageChoice(for: elsewhere, current: world.summary),
            .report(
                "There isn't enough free space for the library there: it needs \(StorageWording.size(size)), "
                    + "and \(StorageWording.size(10)) is free.",
                isRefusal: true
            )
        )

        probes.areOnOneVolume = { _, _ in true }
        XCTAssertEqual(StorageDestinationAssessment.assess(world.empty, context: world.context, probes: probes).verdict, .moveHere)
    }

    // MARK: - While the Library Isn't Available

    /// While the library isn't available nothing can be moved: a folder
    /// holding a library can be used, even the one the library is expected
    /// in, now holding another; an empty or crowded folder is refused, with
    /// what can be chosen instead; nothing is said to be the library in use.
    func testWhileTheLibraryIsNotAvailableOnlyLibrariesCanBeUsed() throws {
        let world = try makeWorld()
        var context = world.context
        context.libraryIsAvailable = false
        let unavailable = StorageChoice.CurrentLibrary(folder: world.current.path, bookCount: 0, isAvailable: false)

        let empty = StorageDestinationAssessment.assess(world.empty, context: context, probes: world.probes)
        XCTAssertEqual(empty.verdict, .refused(.nothingToMove))
        XCTAssertEqual(
            StorageChoice(for: empty, current: unavailable),
            .report(
                "There's no library in \(world.empty.path) to use, and none to move there while the library isn't "
                    + "available. Choose a folder that holds a TextMouth library, or use the default location.",
                isRefusal: true
            )
        )
        XCTAssertEqual(
            StorageDestinationAssessment.assess(world.other, context: context, probes: world.probes).verdict,
            .refused(.otherItems([".hidden", "notes.txt", "photos"]))
        )
        let marked = StorageDestinationAssessment.assess(world.marked, context: context, probes: world.probes)
        XCTAssertEqual(marked.verdict, .useLibrary(.init(identity: try LibraryIdentity.read(in: world.marked), isCopyOfCurrentLibrary: false)))
        guard case .useLibrary = StorageDestinationAssessment.assess(world.current, context: context, probes: world.probes).verdict else {
            return XCTFail("The folder the library is expected in could not be used while unavailable")
        }

        XCTAssertEqual(StorageChoice(for: marked, current: unavailable), .confirm(
            title: "Use This Library?",
            message: "TextMouth will open the library in \(world.marked.path) instead of the one in \(world.current.path), "
                + "which isn't available. Nothing is copied, and nothing is created in \(world.current.path). TextMouth "
                + "will quit and open again to load it.",
            button: "Use This Library",
            action: .useLibrary(at: world.marked)
        ))
    }

    /// While the library isn't available, the default location starts a
    /// new library when it holds none, missing, empty, or holding other
    /// things, and is used as it is when it holds one. The confirmation
    /// says what unsaved changes switching loses.
    func testTheDefaultLocationStartsANewLibraryWhileTheLibraryIsNotAvailable() throws {
        let world = try makeWorld()
        var context = world.context
        context.libraryIsAvailable = false
        let unavailable = StorageChoice.CurrentLibrary(
            folder: world.current.path,
            bookCount: 0,
            isAvailable: false,
            unsavedChanges: ["Library changes are not saved."]
        )

        for prepare in [nil, "empty", "crowded"] {
            context.defaultRoot = world.base.appendingPathComponent("Home \(prepare ?? "missing")/.TextMouth", isDirectory: true)
            if let prepare {
                try FileManager.default.createDirectory(at: context.defaultRoot, withIntermediateDirectories: true)
                if prepare == "crowded" {
                    try Data("log".utf8).write(to: context.defaultRoot.appendingPathComponent("old.log"))
                }
            } else {
                try FileManager.default.createDirectory(
                    at: context.defaultRoot.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }

            let assessment = StorageDestinationAssessment.assess(context.defaultRoot, context: context, probes: world.probes)

            XCTAssertEqual(assessment.verdict, .startNewLibrary, prepare ?? "missing")
            XCTAssertEqual(StorageChoice(for: assessment, current: unavailable), .confirm(
                title: "Start a New Library?",
                message: "TextMouth will start a new, empty library in the default location, \(context.defaultRoot.path), "
                    + "instead of the library in \(world.current.path), which isn't available. Nothing is created in "
                    + "\(world.current.path). TextMouth will quit and open again to start it. Switching loses the "
                    + "changes TextMouth couldn't save while the library isn't available. Library changes are not saved.",
                button: "Start New Library",
                action: .useLibrary(at: context.defaultRoot)
            ))
        }

        context.defaultRoot = world.marked
        guard case .useLibrary = StorageDestinationAssessment.assess(world.marked, context: context, probes: world.probes).verdict else {
            return XCTFail("A library in the default location was not offered for use")
        }
    }

    // MARK: - Assessing for the Library Model

    /// The model's assessment reads its context from the library in use and
    /// runs off the main thread, without changing anything.
    @MainActor
    func testTheModelAssessesFoldersAgainstTheLibraryInUse() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let provider = FakeCloudItemStatusProvider()
        let empty = try makeSandboxDirectory("ModelAssessment").appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        provider.setLocation(.cloud(.iCloudDrive), of: empty)

        let chosen = await StorageDestinationAssessment.assess(empty, for: model, probes: .live(itemStatus: provider))
        let current = await StorageDestinationAssessment.assess(TextMouthPaths.root, for: model, probes: .live(itemStatus: provider))

        XCTAssertEqual(chosen.verdict, .moveHere)
        XCTAssertEqual(chosen.location, .cloud(.iCloudDrive))
        XCTAssertEqual(current.verdict, .currentLibrary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    // MARK: - Fixtures

    /// The folders one test assesses, in a sandbox folder of its own, and
    /// the fake cloud service saying where each lives.
    final class World {
        /// The sandbox folder holding everything.
        let base: URL
        /// The library in use: an identity marker, an index, and three books.
        let current: URL
        /// A folder that does not exist, in a folder that does.
        let missing: URL
        /// An empty folder.
        let empty: URL
        /// A library known by its identity marker alone.
        let marked: URL
        /// A library from before identities: an index beside a Library folder.
        let indexed: URL
        /// A folder holding other things, one of them hidden.
        let other: URL
        /// Where each folder lives.
        let provider = FakeCloudItemStatusProvider()

        init(base: URL) {
            self.base = base
            current = base.appendingPathComponent("Current", isDirectory: true)
            missing = base.appendingPathComponent("Missing", isDirectory: true)
            empty = base.appendingPathComponent("Empty", isDirectory: true)
            marked = base.appendingPathComponent("Marked", isDirectory: true)
            indexed = base.appendingPathComponent("Indexed", isDirectory: true)
            other = base.appendingPathComponent("Other", isDirectory: true)
        }

        /// The library in use, as an assessment knows it.
        var context: StorageDestinationAssessment.Context {
            StorageDestinationAssessment.Context(
                currentRoot: current,
                libraryIsAvailable: true,
                currentIdentity: try? LibraryIdentity.read(in: current)?.id,
                defaultRoot: base.appendingPathComponent("Home/.TextMouth", isDirectory: true)
            )
        }

        /// The system's answers, with the fake saying where folders are.
        var probes: StorageDestinationAssessment.Probes {
            .live(itemStatus: provider)
        }

        /// The library in use, as the words name it.
        var summary: StorageChoice.CurrentLibrary {
            StorageChoice.CurrentLibrary(folder: current.path, bookCount: 3, isAvailable: true)
        }

        /// `folder` assessed for the library in use.
        func assess(_ folder: URL) -> StorageDestinationAssessment {
            StorageDestinationAssessment.assess(folder, context: context, probes: probes)
        }

        /// The status line's sentence for `folder`, or nil when a
        /// confirmation is offered instead.
        func report(_ folder: URL) -> String? {
            guard case .report(let message, _) = StorageChoice(for: assess(folder), current: summary) else { return nil }
            return message
        }
    }

    /// A world of folders for one test.
    private func makeWorld() throws -> World {
        let world = World(base: try makeSandboxDirectory("StorageDestination"))
        let fileManager = FileManager.default
        for folder in [world.current, world.empty, world.marked, world.indexed, world.other] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The library in use.
        _ = try LibraryIdentity.adopt(in: world.current)
        try Data("{\"books\":[],\"folders\":[]}".utf8).write(to: world.current.appendingPathComponent("library.json"))
        let package = world.current.appendingPathComponent("Library/Atlas.tmb", isDirectory: true)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("The atlas opens at the harbor chart.".utf8).write(to: package.appendingPathComponent("book.txt"))
        // A library known by its marker, and one by its index.
        _ = try LibraryIdentity.adopt(in: world.marked)
        try Data("{}".utf8).write(to: world.indexed.appendingPathComponent("library.json"))
        try fileManager.createDirectory(
            at: world.indexed.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Other things.
        try Data("notes".utf8).write(to: world.other.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: world.other.appendingPathComponent(".hidden"))
        try fileManager.createDirectory(
            at: world.other.appendingPathComponent("photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        return world
    }

    /// Sets the permissions of the folder at `folder`, putting them back
    /// when the test ends so its sandbox can be removed.
    private func setPermissions(_ permissions: Int, of folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: folder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
    }
}
