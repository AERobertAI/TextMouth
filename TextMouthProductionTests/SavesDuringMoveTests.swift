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

    // MARK: - Helpers

    /// Puts the substitutions file of the data directory in use now back as
    /// it is now (or leaves none, when there is none) when the test ends, so
    /// the rules a test saves never reach the next test, which shares the
    /// sandbox's data directory and would copy them into its own move.
    private func keepSubstitutionsFile() {
        let file = TextMouthPaths.substitutionsFile
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

/// The data directories in use at each wait for the statistics' queue a
/// move made, in order, on the main actor.
@MainActor
private final class StatisticsWaits {
    /// The data directory's path at each wait.
    var roots: [String] = []
}
