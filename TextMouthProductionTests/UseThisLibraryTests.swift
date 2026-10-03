import XCTest
@testable import TextMouth

/// Use This Library makes a library already in a folder the one TextMouth
/// uses, as it is, and opens TextMouth again so startup runs on it (FR02):
/// the location is recorded through `TextMouthPaths.setCustomRoot`, waiting
/// saves are written first, and changes that can't be saved refuse the
/// switch while they could still be retried. While the library isn't
/// available it still works, with nothing created at the missing location.
/// TextMouth's opening again is recorded, never done.
@MainActor
final class UseThisLibraryTests: XCTestCase {

    /// The location, its bookmark, and the chosen library's identity are
    /// recorded; a save waiting for its timer is written before TextMouth
    /// opens again, then quits; the process keeps its data directory until
    /// it does.
    func testUseThisLibraryRecordsTheLocationFlushesAndOpensTextMouthAgain() async throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let preferences = makeSandboxedPreferences("UseThisLibrary")
        let model = makeModel(preferences: preferences)
        let chosen = try makeLibraryFolder("Chosen")
        let identity = try XCTUnwrap(LibraryIdentity.read(in: chosen))
        let rootBefore = TextMouthPaths.root
        // A change waiting for its save.
        model.library = Library(folders: [BookFolder(name: "Charts To Keep")])
        model.save()
        let relaunch = RelaunchRecord(readingIndexAt: TextMouthPaths.libraryIndexFile)

        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)

        XCTAssertEqual(outcome, .success("Opening the library in \(chosen.path)…"))
        XCTAssertEqual(relaunch.steps, ["open", "quit"])
        XCTAssertEqual(relaunch.foldersSavedWhenOpening, ["Charts To Keep"], "the waiting save was not written before TextMouth opened again")
        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: preferences), chosen.path)
        XCTAssertEqual(DataDirectoryPreferences.expectedIdentity.read(from: preferences), identity.id)
        XCTAssertNotNil(DataDirectoryPreferences.bookmark.read(from: preferences))
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
    }

    /// The default location is recorded as no custom location at all, with
    /// the identity of whatever library is there.
    func testUsingTheDefaultLocationRecordsNoCustomLocation() async throws {
        let preferences = makeSandboxedPreferences("UseDefaultLocation")
        DataDirectoryPreferences.customPath.write("/Volumes/Unplugged/TextMouth", to: preferences)
        let model = makeModel(preferences: preferences)
        let relaunch = RelaunchRecord()

        let outcome = await model.useLibraryReturningOutcome(at: TextMouthPaths.defaultRoot, relaunching: relaunch.relauncher)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertNil(DataDirectoryPreferences.customPath.read(from: preferences))
        XCTAssertNil(DataDirectoryPreferences.bookmark.read(from: preferences))
        XCTAssertEqual(
            DataDirectoryPreferences.expectedIdentity.read(from: preferences),
            DataDirectoryPreferences.identity(in: TextMouthPaths.defaultRoot)?.id
        )
        XCTAssertEqual(relaunch.steps, ["open", "quit"])
    }

    // MARK: - Refusals

    /// While the library is available, a change that can't be saved refuses
    /// the switch, naming it, since Retry Saving could still save it;
    /// nothing is recorded and TextMouth stays open.
    func testUseThisLibraryIsRefusedWhileChangesAreUnsaved() async throws {
        let center = resetFailureCenter()
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: CocoaError(.fileWriteNoPermission))
        let preferences = makeSandboxedPreferences("UseUnsaved")
        let model = makeModel(preferences: preferences)
        let chosen = try makeLibraryFolder("Unsaved")
        let relaunch = RelaunchRecord()

        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)

        let expected = ["Failed to switch libraries: Some changes are not saved, and switching libraries would lose them."]
            + PersistenceBannerRow.rows(for: center.unsavedFailures()).map(\.text)
            + ["Choose Retry Saving, then try again."]
        XCTAssertEqual(outcome, .failure(expected.joined(separator: " ")))
        XCTAssertEqual(relaunch.steps, [])
        XCTAssertNil(DataDirectoryPreferences.customPath.read(from: preferences))
        XCTAssertTrue(center.hasUnsavedChanges, "the unsaved change was given up")
    }

    /// While another operation holds the storage work, switching is refused,
    /// saying what that operation is doing, since quitting would stop it part
    /// way: a data-directory move, Rebuild Directory, a folder edit moving
    /// books between folders, or another switch opening TextMouth again.
    /// Nothing is recorded, TextMouth stays open, and once the hold ends the
    /// switch goes ahead.
    func testUseThisLibraryIsRefusedWhileStorageWorkIsHeld() async throws {
        let refusals: [(reason: StorageHoldReason, refusal: String)] = [
            (.movingDataDirectory, "TextMouth is already moving its data directory. Try again once that move is done."),
            (.rebuildingDirectory, "TextMouth is rebuilding its data directory. Try again when that finishes."),
            (.movingBooksBetweenFolders, "TextMouth is moving books between folders. Try again when that finishes."),
            (.switchingLibraries, "TextMouth is switching to another library and opening again on it."),
        ]
        XCTAssertEqual(
            Set(refusals.map(\.reason)),
            Set(StorageHoldReason.allCases),
            "a kind of hold has no refusal here"
        )
        let preferences = makeSandboxedPreferences("UseWhileHeld")
        let model = makeModel(preferences: preferences)
        let chosen = try makeLibraryFolder("WhileHeld")

        for held in refusals {
            let hold = try StorageBoundary.shared.holdWork(for: held.reason)
            let relaunch = RelaunchRecord()
            let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)
            hold.release()

            XCTAssertEqual(outcome, .failure("Failed to switch libraries: \(held.refusal)"), "held for \(held.reason)")
            XCTAssertEqual(relaunch.steps, [], "held for \(held.reason)")
            XCTAssertNil(DataDirectoryPreferences.customPath.read(from: preferences), "held for \(held.reason)")
        }

        let relaunch = RelaunchRecord()
        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(relaunch.steps, ["open", "quit"])
    }

    /// While a switch opens TextMouth again, it holds the storage work, so
    /// that no move, rebuild, or folder edit can begin and be stopped part
    /// way by the quit; the hold ends with the switch, however it ends.
    func testASwitchHoldsTheStorageWorkWhileTextMouthOpensAgain() async throws {
        let preferences = makeSandboxedPreferences("UseHolds")
        let model = makeModel(preferences: preferences)
        let chosen = try makeLibraryFolder("Holds")
        var refusalWhileOpening: Error?
        let relauncher = TextMouthRelauncher(
            openNewInstance: {
                do {
                    try StorageBoundary.shared.holdWork(for: .rebuildingDirectory).release()
                } catch {
                    refusalWhileOpening = error
                }
            },
            quit: {}
        )

        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relauncher)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(refusalWhileOpening as? StorageBusyError, StorageBusyError(reason: .switchingLibraries))
        XCTAssertNoThrow(try StorageBoundary.shared.holdWork(for: .rebuildingDirectory).release(), "the switch kept its hold")
    }

    /// When TextMouth can't open again by itself, the choice stands for the
    /// next launch, it stays open, and says to quit and open it again.
    func testAFailedRelaunchSaysToOpenTextMouthAgain() async throws {
        let preferences = makeSandboxedPreferences("UseFailedRelaunch")
        let model = makeModel(preferences: preferences)
        let chosen = try makeLibraryFolder("FailedRelaunch")
        let failure = CocoaError(.fileReadNoPermission)
        let relaunch = RelaunchRecord(failingWith: failure)

        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)

        XCTAssertEqual(outcome, .failure(
            "TextMouth will open the library in \(chosen.path) the next time it opens, but it couldn't open again by "
                + "itself: \(failure.localizedDescription) Quit TextMouth and open it again."
        ))
        XCTAssertEqual(relaunch.steps, ["open"])
        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: preferences), chosen.path)
    }

    // MARK: - While the Library Isn't Available

    /// While the library isn't available, Use This Library still switches,
    /// gives up the changes the missing library couldn't take, as the
    /// confirmation said, so quitting doesn't ask about them, and creates
    /// nothing at the missing location.
    func testWhileTheLibraryIsUnavailableUseThisLibraryStillSwitches() async throws {
        let center = resetFailureCenter()
        let scratch = try makeDataDirectoryMoveDestination("UseWhileUnavailable").deletingLastPathComponent()
        let missing = scratch.appendingPathComponent("Unplugged/TextMouth", isDirectory: true)
        let preferences = makeSandboxedPreferences("UseWhileUnavailable")
        TextMouthPaths.setCustomRoot(missing, in: preferences)
        StorageBoundary.shared.publish(root: missing)
        addTeardownBlock { DataDirectoryGate.open(missing) }
        let model = LibraryViewModel(dataDirectoryEnvironment: environment(preferences))
        XCTAssertNotNil(model.dataDirectoryUnavailability)
        center.recordFailure(.libraryIndex, path: missing.appendingPathComponent("library.json").path, error: DataDirectoryUnavailableError(root: missing))
        let chosen = try makeLibraryFolder("Rescue")
        let relaunch = RelaunchRecord()

        let outcome = await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher)

        XCTAssertEqual(outcome, .success("Opening the library in \(chosen.path)…"))
        XCTAssertEqual(relaunch.steps, ["open", "quit"])
        XCTAssertFalse(center.hasUnsavedChanges, "what the missing library couldn't take was not given up")
        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: preferences), chosen.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "something was created at the missing location")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path),
            "something was created above the missing location"
        )
    }

    // MARK: - Fixtures

    /// A library model with no startup of its own, reading and writing
    /// `preferences`.
    private func makeModel(preferences: UserDefaults) -> LibraryViewModel {
        LibraryViewModel(initializeServices: false, dataDirectoryEnvironment: environment(preferences))
    }

    /// An environment of the test's own around `preferences`.
    private func environment(_ preferences: UserDefaults) -> DataDirectoryEnvironment {
        DataDirectoryEnvironment(preferences: preferences, volumeNotifications: NotificationCenter())
    }

    /// A folder holding a TextMouth library: an identity marker, an index,
    /// and a Library folder, in a sandbox folder of the test's own.
    private func makeLibraryFolder(_ label: String) throws -> URL {
        let folder = try makeSandboxDirectory(label).appendingPathComponent("TextMouth", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"books\":[],\"folders\":[]}".utf8).write(to: folder.appendingPathComponent("library.json"))
        _ = try LibraryIdentity.adopt(in: folder)
        return folder
    }

    /// The shared failure center, emptied now and when the test ends.
    private func resetFailureCenter() -> PersistenceFailureCenter {
        let center = PersistenceFailureCenter.shared
        center.reset()
        addTeardownBlock { @MainActor in center.reset() }
        return center
    }
}

/// Records how TextMouth was asked to open again, opening and quitting
/// nothing: each step, and the folders the library index on disk held when
/// the new instance was asked for.
@MainActor
private final class RelaunchRecord {
    /// "open" and "quit", in the order asked.
    private(set) var steps: [String] = []
    /// The folder names in the library index when "open" was asked, when
    /// an index to read was given.
    private(set) var foldersSavedWhenOpening: [String]?
    /// The library index read when "open" is asked, if any.
    private let index: URL?
    /// What opening throws, if anything.
    private let failure: Error?

    init(readingIndexAt index: URL? = nil, failingWith failure: Error? = nil) {
        self.index = index
        self.failure = failure
    }

    /// The relauncher recording here.
    var relauncher: TextMouthRelauncher {
        TextMouthRelauncher(
            openNewInstance: { [self] in
                steps.append("open")
                if let index {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let library = try? decoder.decode(Library.self, from: Data(contentsOf: index))
                    foldersSavedWhenOpening = library?.folders.map(\.name)
                }
                if let failure {
                    throw failure
                }
            },
            quit: { [self] in steps.append("quit") }
        )
    }
}
