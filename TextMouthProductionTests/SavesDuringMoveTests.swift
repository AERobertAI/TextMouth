import XCTest
@testable import TextMouth

/// Files the app saves from outside the storage work (the substitution rules
/// from the rules editor, the listening statistics on their own queue) while
/// a data-directory move copies the library (B13). Such a save writes the
/// data directory being copied, which the copy may already have passed, so
/// the moved library used to keep the older file while the old one held the
/// change, and the save was reported done. The save is now provisional
/// (`StorageBoundary.isProvisionalSave(of:rewrite:)`): the move saves the
/// file again once it has ended, in the data directory the library lives in
/// then, and nothing is reported saved before that.
///
/// A save is made at the one moment that leaves the most behind: every item
/// is copied and nothing is published yet.
@MainActor
final class SavesDuringMoveTests: XCTestCase {

    // MARK: - The Moved Library Has What Was Saved During the Copy

    /// Rules saved once the copy has passed substitutions.json are in the
    /// moved library, and the old library holds them too.
    func testRulesSavedWhileTheLibraryIsCopiedAreInTheMovedLibrary() async throws {
        let world = try makeIntegrationWorld("Saves Move Rules")
        keepSubstitutionsFile()
        let destination = try makeDataDirectoryMoveDestination("RulesSavedDuringMove")
        let oldFile = TextMouthPaths.substitutionsFile
        let service = TextSubstitutionService(rules: [])
        let rule = SubstitutionRule(name: "Saved mid-copy", pattern: "harbour", replacement: "harbor")
        let during = SaveDuringCopy()

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(
            during.observer(saving: { service.addRule(rule) })
        ) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(during.saves, 1, "the save during the copy did not run")
        XCTAssertEqual(
            try Self.rules(in: destination.appendingPathComponent("substitutions.json")),
            [rule],
            "the moved library does not have the rules saved while it was copied"
        )
        XCTAssertEqual(try Self.rules(in: oldFile), [rule], "the library the move began in lost the change")
        XCTAssertTrue(TextMouthPaths.substitutionsFile.path.hasPrefix(destination.path + "/"))
        // The save to be made again holds the service weakly.
        withExtendedLifetime(service) {}
    }

    /// Statistics saved once the copy has passed reading_stats.json are in
    /// the moved library.
    func testStatisticsSavedWhileTheLibraryIsCopiedAreInTheMovedLibrary() async throws {
        let world = try makeIntegrationWorld("Saves Move Statistics")
        let destination = try makeDataDirectoryMoveDestination("StatisticsSavedDuringMove")
        let during = SaveDuringCopy()

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(
            during.observer(saving: {
                ReadingStatsService.shared.markBookFinished(bookID: UUID(), title: "Heard mid-copy")
            })
        ) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }
        // The statistics are written on a queue of their own.
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(during.saves, 1, "the save during the copy did not run")
        let moved = ReadingStatsService(fileURL: destination.appendingPathComponent("reading_stats.json"))
        defer { moved.shutdown() }
        XCTAssertEqual(
            moved.stats.finishedBooks.map(\.title),
            ["Heard mid-copy"],
            "the moved library does not have the statistics saved while it was copied"
        )
    }

    /// A move that ends in Cancel after a save during its copy leaves the
    /// change in the library it began in, which is still the library.
    func testRulesSavedDuringAMoveThatIsCancelledStayInTheLibrary() async throws {
        let world = try makeIntegrationWorld("Saves Move Cancelled")
        keepSubstitutionsFile()
        let destination = try makeDataDirectoryMoveDestination("RulesSavedDuringCancelledMove")
        let oldRoot = TextMouthPaths.root
        let oldFile = TextMouthPaths.substitutionsFile
        let service = TextSubstitutionService(rules: [])
        let rule = SubstitutionRule(name: "Saved before Cancel", pattern: "colour", replacement: "color")
        let during = SaveDuringCopy()

        _ = await DataDirectoryMigrator.$copyObserver.withValue(
            during.observer(saving: { service.addRule(rule) }, thenCancelling: true)
        ) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertEqual(during.saves, 1, "the save during the copy did not run")
        XCTAssertEqual(TextMouthPaths.root.path, oldRoot.path, "the cancelled move published its copy")
        XCTAssertEqual(try Self.rules(in: oldFile), [rule], "the change was lost with the cancelled move")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the cancelled move left a copy")
        withExtendedLifetime(service) {}
    }

    // MARK: - Nothing Is Called Saved Early

    /// A save during the copy does not settle a failed save of the rules: it
    /// reached the library being copied, so the center still says the rules
    /// are unsaved until the move has saved them again in the moved library.
    func testASaveDuringTheCopyDoesNotSettleAFailedSaveBeforeTheMoveEnds() async throws {
        let center = cleanSharedFailureCenter()
        let world = try makeIntegrationWorld("Saves Move Failure")
        keepSubstitutionsFile()
        let destination = try makeDataDirectoryMoveDestination("RulesFailedSaveDuringMove")
        let oldFile = TextMouthPaths.substitutionsFile
        let obstruction = try WriteObstruction.place(at: oldFile)
        let service = TextSubstitutionService(rules: [])
        let rule = SubstitutionRule(name: "Failed, then saved", pattern: "grey", replacement: "gray")
        service.addRule(rule)
        XCTAssertTrue(center.hasUnsavedChanges, "the failed save was not reported")
        // The failure came from the place, not the rules: the copy takes a plain library.
        obstruction.clear()
        let during = SaveDuringCopy()

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(
            during.observer(saving: {
                service.saveRules()
                during.unsavedChangesAfterTheSave = center.hasUnsavedChanges
            })
        ) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(
            during.unsavedChangesAfterTheSave, true,
            "the rules were called saved while the move was still copying the library they were saved in"
        )
        XCTAssertFalse(center.hasUnsavedChanges, "the rules are not saved in the moved library")
        XCTAssertEqual(try Self.rules(in: destination.appendingPathComponent("substitutions.json")), [rule])
        withExtendedLifetime(service) {}
    }

    /// Rebuild Directory writes the data directory it is in, so a save of
    /// the rules while it holds the storage work is final: it is written and
    /// reported at once, and nothing is saved again afterwards.
    func testASaveDuringARebuildIsFinalAtOnce() throws {
        let center = cleanSharedFailureCenter()
        _ = try makeIntegrationWorld("Saves Rebuild")
        keepSubstitutionsFile()
        let oldFile = TextMouthPaths.substitutionsFile
        let obstruction = try WriteObstruction.place(at: oldFile)
        let service = TextSubstitutionService(rules: [])
        service.addRule(SubstitutionRule(name: "Failed first", pattern: "tyre", replacement: "tire"))
        XCTAssertTrue(center.hasUnsavedChanges)
        obstruction.clear()
        let hold = try StorageBoundary.shared.holdWork(for: .rebuildingDirectory)
        defer { hold.release() }

        service.saveRules()

        XCTAssertFalse(center.hasUnsavedChanges, "a save during a rebuild was held back as if a move were copying")
        // Nothing was owed: this ends the rebuild's hold and finds nothing to save.
        hold.release()
        try? FileManager.default.removeItem(at: oldFile)
        StorageBoundary.shared.rewriteFilesSavedDuringTheMove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "a save was made again after a rebuild")
        withExtendedLifetime(service) {}
    }

    // MARK: - Only the Copy Is Provisional

    /// A save made while the move only waits for other work is copied with
    /// the library, so it is final: it settles an earlier failure at once.
    /// Held back until the move ended, it left a quit, which does not wait
    /// for a move that has not begun copying, calling saved rules unsaved.
    func testASaveWhileTheMoveWaitsForOtherWorkIsFinal() async throws {
        let center = cleanSharedFailureCenter()
        let world = try makeIntegrationWorld("Saves Move Waiting")
        keepSubstitutionsFile()
        let destination = try makeDataDirectoryMoveDestination("RulesSavedWhileTheMoveWaits")
        let oldFile = TextMouthPaths.substitutionsFile
        let obstruction = try WriteObstruction.place(at: oldFile)
        let service = TextSubstitutionService(rules: [])
        let rule = SubstitutionRule(name: "Saved while waiting", pattern: "kerb", replacement: "curb")
        service.addRule(rule)
        XCTAssertTrue(center.hasUnsavedChanges, "the failed save was not reported")
        obstruction.clear()
        // Work under way that the move must wait for, held until the move says it waits.
        let gate = makeGate()
        let working = expectation(description: "the work under way began")
        DispatchQueue.global().async {
            StorageBoundary.shared.perform(.textExtraction) { _ in
                working.fulfill()
                gate.wait()
            }
        }
        await fulfillment(of: [working], timeout: 10)
        let waiting = SaveDuringCopy()

        let outcome = await world.library.moveDataDirectoryReturningOutcome(to: destination) { work in
            guard work == .textExtraction else { return }
            service.saveRules()
            waiting.unsavedChangesAfterTheSave = center.hasUnsavedChanges
            gate.signal()
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(
            waiting.unsavedChangesAfterTheSave, false,
            "a save made before the copy began was held back, though the copy takes it"
        )
        XCTAssertEqual(try Self.rules(in: destination.appendingPathComponent("substitutions.json")), [rule])
        withExtendedLifetime(service) {}
    }

    /// A file saved before the publish and again after it is saved again
    /// once, not once for each place it was written.
    func testAFileSavedBeforeAndAfterThePublishIsSavedAgainOnce() throws {
        _ = try makeIntegrationWorld("Saves Move Twice")
        keepSubstitutionsFile()
        let moved = try makeDataDirectoryMoveDestination("RulesSavedBeforeAndAfterThePublish")
        let service = TextSubstitutionService(rules: [])
        let hold = try StorageBoundary.shared.holdWork(for: .movingDataDirectory)
        defer { hold.release() }
        StorageBoundary.shared.beginProvisionalSaves()

        service.addRule(SubstitutionRule(name: "Before", pattern: "a", replacement: "b"))
        StorageBoundary.shared.publish(root: moved)
        service.addRule(SubstitutionRule(name: "After", pattern: "c", replacement: "d"))
        hold.release()

        XCTAssertEqual(StorageBoundary.shared.rewriteFilesSavedDuringTheMove(), 1, "the file was saved again for each place it was written")
        withExtendedLifetime(service) {}
    }

    // MARK: - The Outcome Is Judged After the Statistics Are Written

    /// The move waits for the statistics' write after saving them again,
    /// before Storage settings judge its outcome: a failed statistics save
    /// the rewrite settles is never reported unsaved just before it does.
    /// The wait is made twice, once before the copy (in the old data
    /// directory) and once after the rewrite (in the new one); the outcome
    /// is then reported done.
    func testTheStatisticsAreWrittenAgainBeforeTheMovesOutcomeIsJudged() async throws {
        let center = cleanSharedFailureCenter()
        let world = try makeIntegrationWorld("Saves Move Statistics Judged")
        let destination = try makeDataDirectoryMoveDestination("StatisticsJudgedAfterMove")
        let oldRoot = TextMouthPaths.root.path
        center.recordFailure(
            .statistics,
            path: "/data/reading_stats.json",
            error: NSError(domain: "SavesDuringMoveTests", code: 1)
        ) { _ in }
        XCTAssertTrue(center.hasUnsavedChanges, "the failed save was not reported")
        let during = SaveDuringCopy()
        let waits = StatisticsWaits()

        let outcome = await LibraryViewModel.$waitForQueuedStatisticsSaves.withValue({
            ReadingStatsService.waitForQueuedSaves()
            MainActor.assumeIsolated { waits.roots.append(TextMouthPaths.root.path) }
        }) {
            await DataDirectoryMigrator.$copyObserver.withValue(
                during.observer(saving: {
                    ReadingStatsService.shared.markBookFinished(bookID: UUID(), title: "Heard mid-copy")
                })
            ) {
                await world.library.moveDataDirectoryReturningOutcome(to: destination)
            }
        }
        let judged = world.library.outcomeConfirmingSaves(outcome)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(
            waits.roots, [oldRoot, TextMouthPaths.root.path],
            "the move did not wait for the statistics' write after saving them again"
        )
        XCTAssertEqual(judged, outcome, "the finished move was reported failed for statistics about to be saved")
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    // MARK: - The Filter Presets Follow the Move (B14 review)

    /// The filter presets are saved from Settings, outside the storage work,
    /// as the rules are. A first preset saved once the copy has passed the
    /// top of the data directory has no file to be copied, so the moved
    /// library used to lack it, the preset left only in the old folder (with
    /// the temporary file of its save listed, the move used to fail instead).
    /// The move saves it again in the moved library.
    func testAFilterPresetSavedWhileTheLibraryIsCopiedIsInTheMovedLibrary() async throws {
        let world = try makeIntegrationWorld("Saves Move Presets")
        keepFile(TextMouthPaths.audioFiltersFile)
        // No file yet, as at a first save; the teardown puts back any that was.
        try? FileManager.default.removeItem(at: TextMouthPaths.audioFiltersFile)
        let destination = try makeDataDirectoryMoveDestination("PresetSavedDuringMove")
        let oldFile = TextMouthPaths.audioFiltersFile
        // The pane, opened before the move, with no presets file yet.
        let library = AudioFilterPresetLibrary()
        XCTAssertTrue(library.standsInForMissingFile, "a presets file was already there")
        let during = SaveDuringCopy()

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(
            during.observer(saving: { _ = try? library.add(name: "Phone Line", chain: "highpass=f=300") })
        ) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(during.saves, 1, "the save during the copy did not run")
        let moved = AudioFilterPresetLibrary(url: destination.appendingPathComponent(AudioFilterPresetLibrary.fileName))
        XCTAssertEqual(moved.presets.last?.name, "Phone Line", "the moved library does not have the preset saved while it was copied")
        XCTAssertFalse(moved.standsInForMissingFile)
        XCTAssertEqual(AudioFilterPresetLibrary(url: oldFile).presets.last?.name, "Phone Line", "the library the move began in lost it")
    }

    /// A pane left open through a move saves in the library then in use: its
    /// file is looked up at each save, not kept from when the pane opened.
    func testAFilterPresetSavedAfterAMoveIsSavedInTheNewDataDirectory() async throws {
        let world = try makeIntegrationWorld("Saves Move Presets After")
        keepFile(TextMouthPaths.audioFiltersFile)
        // No file yet, as at a first save; the teardown puts back any that was.
        try? FileManager.default.removeItem(at: TextMouthPaths.audioFiltersFile)
        let destination = try makeDataDirectoryMoveDestination("PresetSavedAfterMove")
        let oldFile = TextMouthPaths.audioFiltersFile
        let library = AudioFilterPresetLibrary()
        let outcome = await world.library.moveDataDirectoryReturningOutcome(to: destination)
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")

        try library.add(name: "Radio Voice", chain: "highpass=f=200")

        let moved = AudioFilterPresetLibrary(url: destination.appendingPathComponent(AudioFilterPresetLibrary.fileName))
        XCTAssertEqual(moved.presets.last?.name, "Radio Voice", "the preset was not saved in the new data directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "the preset was saved in the old data directory")
    }

    // MARK: - A Save's Temporary File Never Fails the Move (B14)

    /// A save writes a temporary file beside its target and renames it into
    /// place. One the copy's listing names, renamed away before the copy
    /// reached it, used to stop the move with "couldn't be opened because
    /// there is no such file". It is no item of the copy: the move ends, and
    /// the save's result is in the moved library.
    func testASavesTemporaryFileListedThenRenamedAwayDoesNotFailTheMove() async throws {
        try await assertATemporaryFileRenamedAwayDoesNotFailTheMove(named: ".dat.nosync8247.Ab12Cd")
    }

    /// The same for the other name Foundation gives an atomic write's file,
    /// the one the hosted runner's macOS makes: the target's name, ".sb-",
    /// eight hexadecimal digits, a dash, and six letters or digits.
    func testASafeSaveTemporaryFileListedThenRenamedAwayDoesNotFailTheMove() async throws {
        try await assertATemporaryFileRenamedAwayDoesNotFailTheMove(named: "substitutions.json.sb-42f471cf-2CWLTV")
    }

    /// Plants the temporary file `name` beside substitutions.json, renames it
    /// over the file once the copy has listed the data directory, and checks
    /// the move ends with the save in the moved library and the temporary
    /// file left out.
    private func assertATemporaryFileRenamedAwayDoesNotFailTheMove(named name: String) async throws {
        let world = try makeIntegrationWorld("Saves Move Temporary")
        keepSubstitutionsFile()
        let destination = try makeDataDirectoryMoveDestination("TemporaryFileRenamedAway")
        let target = TextMouthPaths.substitutionsFile
        // A file the copy lists, which the save replaces.
        try Data("[]".utf8).write(to: target)
        // The save under way when the copy lists the data directory: its
        // temporary file, written beside the target.
        let rule = SubstitutionRule(name: "Saved by rename", pattern: "plough", replacement: "plow")
        let temporary = TextMouthPaths.root.appendingPathComponent(name)
        try JSONEncoder().encode([rule]).write(to: temporary)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        // The save ends once the plan is made and before the first item.
        let ending = ChangeBeforeFirstItem {
            try? SavedFile.renameReplacing(temporary, target)
        }

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(ending.observer()) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertEqual(ending.runs, 1, "the save did not end during the copy")
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(
            try Self.rules(in: destination.appendingPathComponent("substitutions.json")),
            [rule],
            "the moved library does not have what the save wrote"
        )
        XCTAssertFalse(
            Self.entryNames(in: destination).contains(temporary.lastPathComponent),
            "the save's temporary file was copied into the moved library"
        )
    }

    /// A file the user has that vanishes between the listing and its copy is
    /// not a temporary file: the move still stops with the system's words,
    /// and nothing is published, so the new library never lacks a file the
    /// old one had.
    func testARealFileThatVanishesDuringTheCopyStillFailsTheMove() async throws {
        let world = try makeIntegrationWorld("Saves Move Vanished")
        let destination = try makeDataDirectoryMoveDestination("RealFileVanished")
        let oldRoot = TextMouthPaths.root
        // Neither a temporary name nor a saved file of the app's: a name
        // the copy must not take for a save's.
        let file = oldRoot.appendingPathComponent("Vanishing Notes B14.json")
        try Data("{}".utf8).write(to: file)
        let elsewhere = try makeSandboxDirectory("RealFileVanishedTo").appendingPathComponent("Vanishing Notes B14.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let vanishing = ChangeBeforeFirstItem {
            try? FileManager.default.moveItem(at: file, to: elsewhere)
        }

        let outcome = await DataDirectoryMigrator.$copyObserver.withValue(vanishing.observer()) {
            await world.library.moveDataDirectoryReturningOutcome(to: destination)
        }

        XCTAssertEqual(vanishing.runs, 1, "the file did not vanish during the copy")
        XCTAssertFalse(outcome.succeeded, "the move was reported done without a file the library had")
        XCTAssertTrue(
            outcome.failureMessage?.contains("Vanishing Notes B14") == true,
            "the failure does not name the file that vanished: \(outcome.failureMessage ?? "no message")"
        )
        XCTAssertEqual(TextMouthPaths.root.path, oldRoot.path, "the failed move published its copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the failed move left a copy")
    }

    /// A temporary file an earlier crash left is not the library's: it is
    /// not copied into the moved library, and the old library keeps it.
    func testAStaleTemporaryFileIsNotCopiedAndStaysWhereItWas() async throws {
        let world = try makeIntegrationWorld("Saves Move Stale")
        let destination = try makeDataDirectoryMoveDestination("StaleTemporaryFile")
        let oldRoot = TextMouthPaths.root
        let stale = [
            ".dat.nosync1a2b.StaLe0",
            "substitutions.json.sb-1a2b3c4d-StaLe0",
            SaveTemporaryNames.stagedName(for: TranscriptCleanupRuleFile.fileName),
        ].map { oldRoot.appendingPathComponent($0) }
        for file in stale {
            try Data("left by a crash".utf8).write(to: file)
            addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        }
        // A look-alike a user could have is copied as any file is.
        let hidden = oldRoot.appendingPathComponent(".dat.nosync-notes")
        try Data("mine".utf8).write(to: hidden)
        addTeardownBlock { try? FileManager.default.removeItem(at: hidden) }

        // A folder a user may have made, named like a staged file of a target
        // no save stages: copied with what is in it.
        let folder = oldRoot.appendingPathComponent(".Old Books.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: folder.appendingPathComponent("Tide Notes.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let outcome = await world.library.moveDataDirectoryReturningOutcome(to: destination)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        // Each stale file's own name, not the matcher's idea of one.
        let copied = Self.entryNames(in: destination)
        for file in stale {
            XCTAssertFalse(copied.contains(file.lastPathComponent), "\(file.lastPathComponent) was copied")
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("\(folder.lastPathComponent)/Tide Notes.txt")),
            Data("kept".utf8),
            "a folder named like a temporary file was left out of the copy"
        )
        for file in stale {
            XCTAssertEqual(
                try Data(contentsOf: file), Data("left by a crash".utf8),
                "\(file.lastPathComponent) was changed or removed from the old library"
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(".dat.nosync-notes")), Data("mine".utf8),
            "a look-alike name was left out of the copy"
        )
    }

    // MARK: - Helpers

    /// The name of every item in the folder `folder` and the folders in it,
    /// at any depth, each without its path.
    private static func entryNames(in folder: URL) -> Set<String> {
        let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return Set(paths.map { ($0 as NSString).lastPathComponent })
    }

    /// Puts the substitutions file of the data directory in use now back as
    /// it is now (or leaves none, when there is none) when the test ends, so
    /// the rules a test saves never reach the next test, which shares the
    /// sandbox's data directory and would copy them into its own move.
    private func keepSubstitutionsFile() {
        keepFile(TextMouthPaths.substitutionsFile)
    }

    /// Puts `file` back as it is now (or leaves none, when there is none)
    /// when the test ends, as `keepSubstitutionsFile()` does for the rules.
    private func keepFile(_ file: URL) {
        let original = try? Data(contentsOf: file)
        addTeardownBlock {
            if let original {
                try? original.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The rules the substitutions file at `url` holds.
    private static func rules(in url: URL) throws -> [SubstitutionRule] {
        try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: url))
    }
}

/// A save made on the main actor at the moment a move's copy has taken
/// every item and nothing is published yet.
@MainActor
private final class SaveDuringCopy {
    /// How many times the save ran.
    private(set) var saves = 0
    /// What a test noted just after the save, on the main actor.
    var unsavedChangesAfterTheSave: Bool?
    /// Whether Cancel is asked for once the save was made.
    private var cancelsAfterTheSave = false

    /// An observer that runs `save` once the copy is complete, and, when
    /// `thenCancelling`, says the move was cancelled from then on, which
    /// stops the move once the last item is in.
    nonisolated func observer(
        saving save: @escaping @MainActor @Sendable () -> Void,
        thenCancelling: Bool = false
    ) -> DataDirectoryCopyObserver {
        DataDirectoryCopyObserver(
            report: { [self] progress in
                guard progress.isComplete else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        saves += 1
                        save()
                        cancelsAfterTheSave = thenCancelling
                    }
                }
            },
            isCancelled: { [self] in
                DispatchQueue.main.sync { MainActor.assumeIsolated { cancelsAfterTheSave } }
            }
        )
    }
}

/// A change made to the data directory being copied once the copy has listed
/// it and before it copies its first item (B14): the moment a save under
/// way ends, or a file goes. It runs on the copy's thread, once.
private final class ChangeBeforeFirstItem: @unchecked Sendable {
    /// Guards `count`.
    private let lock = NSLock()
    /// How many times the change was made.
    private var count = 0
    /// The change.
    private let change: @Sendable () -> Void

    /// A change to make before the first item is copied.
    init(_ change: @escaping @Sendable () -> Void) {
        self.change = change
    }

    /// How many times the change was made.
    var runs: Int {
        lock.withLock { count }
    }

    /// An observer that makes the change when it hears of the copy's start,
    /// with no item copied, and never asks for Cancel.
    func observer() -> DataDirectoryCopyObserver {
        DataDirectoryCopyObserver(
            report: { [self] progress in
                guard progress.copiedItems == 0, lock.withLock({ count == 0 }) else { return }
                change()
                lock.withLock { count += 1 }
            },
            isCancelled: { false }
        )
    }
}

/// The data directories in use at each wait for the statistics' queue a
/// move made, in order, on the main actor.
@MainActor
private final class StatisticsWaits {
    /// The data directory's path at each wait.
    var roots: [String] = []
}
