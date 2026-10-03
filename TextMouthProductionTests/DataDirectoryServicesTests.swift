import XCTest
@testable import TextMouth

/// The services that read a file of the data directory once (FR02): made
/// while the library model has found the data directory unavailable, they
/// neither read that file nor take its absence for a first launch, so their
/// stand-ins are never saved over it; once the library is back, they read
/// the file.
@MainActor
final class DataDirectoryServicesTests: XCTestCase {

    /// The substitution rules stand in as the standard ones, unsaved, while
    /// the library is unavailable, and the library's own rules replace them
    /// once it is back.
    func testSubstitutionRulesWaitForTheLibrary() throws {
        let sandboxRoot = TextMouthPaths.root
        let root = try makeCurrentDataDirectory("RulesAway")
        let own = [SubstitutionRule(name: "Harbor", pattern: "hbr", replacement: "harbor", isRegex: false)]
        let file = root.appendingPathComponent("substitutions.json")
        let fileBytes = try JSONEncoder().encode(own)
        try fileBytes.write(to: file)
        let service = TextSubstitutionService.shared
        addTeardownBlock { @MainActor in
            // The shared service reads the test host's own rules again.
            restoreDataDirectory(sandboxRoot)
            service.loadRules()
        }
        DataDirectoryGate.close(root)

        service.loadRules()

        XCTAssertTrue(service.rulesAwaitDataDirectory)
        XCTAssertEqual(service.rules.map(\.name), TextSubstitutionService.defaultRules.map(\.name))
        XCTAssertEqual(try Data(contentsOf: file), fileBytes, "the stand-ins were saved over the library's rules")

        DataDirectoryGate.open(root)
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)

        XCTAssertFalse(service.rulesAwaitDataDirectory)
        XCTAssertEqual(service.rules.map(\.name), ["Harbor"])
    }

    /// Statistics made while the library is unavailable start empty, without
    /// reading the file, and the library's own replace them once it is back.
    func testStatisticsWaitForTheLibrary() throws {
        let root = try makeCurrentDataDirectory("StatisticsAway")
        var saved = ReadingStats()
        saved.totalListeningSeconds = 5_400
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: root.appendingPathComponent("reading_stats.json"))
        DataDirectoryGate.close(root)

        let service = ReadingStatsService()
        addTeardownBlock { @MainActor in service.shutdown() }

        XCTAssertTrue(service.statsAwaitDataDirectory)
        XCTAssertEqual(service.stats.totalListeningSeconds, 0)

        DataDirectoryGate.open(root)
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)

        XCTAssertFalse(service.statsAwaitDataDirectory)
        XCTAssertEqual(service.stats.totalListeningSeconds, 5_400)
    }

    // MARK: - Fixtures

    /// A data directory of the test's own, with its Library folder, made the
    /// current one until the test ends, and its gate opened then.
    private func makeCurrentDataDirectory(_ label: String) throws -> URL {
        let root = try makeDataDirectoryMoveDestination(label)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }
        return root
    }
}
