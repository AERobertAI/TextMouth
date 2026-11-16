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

    // MARK: - Helpers

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
