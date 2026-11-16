import XCTest
@testable import TextMouth

/// A test's config saves are over before its folders go (Q-flake).
///
/// A settings change asks its `ConfigService` for a save that waits 250
/// milliseconds for more changes (`scheduleSave()`). A test that ended inside
/// that wait deleted its folders first, so the save fired after them, failed
/// with "The folder "config.json" doesn't exist", and the failure center
/// announced "Settings could not be saved" into whichever test was running
/// then: `ReaderCloudDownloadTests` on a subset's runs, as the feed tests'
/// last writes were once heard in `LibraryFeedMoveToFolderTests`.
///
/// The fix is in the tests: every config service a test makes comes from
/// `makeConfigService(fileURL:)`, whose teardown drops the save still
/// waiting (`ConfigService.cancelScheduledSave()`), and these tests check
/// that, and that the sources keep to it. The app stays as it was: a config
/// folder that is missing there is a failure the user must hear, and one
/// test here pins that.
@MainActor
final class ConfigTestWorldTeardownTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start from a center with no settings failure, so the checks below
        // see only what this test makes.
        PersistenceFailureCenter.shared.recordSuccess(.configuration)
    }

    // MARK: - Dropping a waiting save

    /// A waiting save that is dropped never writes: the file is not made, no
    /// failure is reported, and the service has nothing waiting. A save
    /// asked for afterwards still works.
    func testADroppedSaveNeverWrites() throws {
        let file = try makeConfigFileURL()
        let service = makeConfigService(fileURL: file, saveDelay: .milliseconds(50))
        service.config.wordsPerMinute = 321
        service.scheduleSave()
        XCTAssertTrue(service.hasScheduledSave)

        service.cancelScheduledSave()
        XCTAssertFalse(service.hasScheduledSave)
        spin(for: 0.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a dropped save wrote the file")
        XCTAssertEqual(PersistenceFailureCenter.shared.outstandingFailures().map(\.subject), [])

        // Dropping when nothing waits changes nothing.
        service.cancelScheduledSave()
        service.scheduleSave()
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: file.path) }, "a later save never wrote")
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 321)
    }

    /// In the app a config folder that is missing as a save fires is a real
    /// failure, reported for the user to hear and retry; only the test's own
    /// teardown drops a save. The failure is settled again here, so it is
    /// never heard by another test.
    func testASaveWhoseFolderIsGoneIsStillAFailureTheUserHears() throws {
        let file = try makeConfigFileURL()
        let service = makeConfigService(fileURL: file, saveDelay: .milliseconds(50))
        service.config.wordsPerMinute = 322
        service.scheduleSave()
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        defer { PersistenceFailureCenter.shared.recordSuccess(.configuration) }

        XCTAssertTrue(
            eventually { PersistenceFailureCenter.shared.outstandingFailures().map(\.subject) == [.configuration] },
            "the save into a missing folder was not reported"
        )
    }

    // MARK: - The Helper's Teardown

    /// The helper's teardown drops the save a test leaves waiting. This test
    /// registers its check first, so it runs after the helper's own teardown
    /// block (blocks run last registered first): once the test is over, the
    /// service has no save left to fire after the test's folders are gone.
    func testTheHelpersTeardownDropsASaveLeftWaiting() throws {
        let made = MadeService()
        addTeardownBlock {
            XCTAssertEqual(made.service?.hasScheduledSave, false, "the helper's teardown left a save waiting")
        }
        let service = makeConfigService(fileURL: try makeConfigFileURL())
        made.service = service
        service.config.wordsPerMinute = 333
        service.scheduleSave()
        XCTAssertTrue(service.hasScheduledSave, "the test has no save waiting to be dropped")
    }

    /// The same end with a service made by hand, as tests made them before
    /// the helper, leaves its save waiting past the teardown: it would fire
    /// after the folders were deleted. This keeps the test above honest,
    /// since it shows that without the helper's block the check finds a save
    /// waiting. The save is dropped afterwards, so it fires nowhere.
    func testAServiceMadeByHandLeavesItsSaveWaitingPastTheTeardown() throws {
        let made = MadeService()
        // Registered first, so it runs last: it drops what the check found.
        addTeardownBlock { made.service?.cancelScheduledSave() }
        addTeardownBlock {
            XCTAssertEqual(made.service?.hasScheduledSave, true, "a service made by hand had no save waiting")
        }
        // Made by hand, as the guard below forbids everywhere else.
        let service = ConfigService(fileURL: try makeConfigFileURL())
        made.service = service
        service.config.wordsPerMinute = 333
        service.scheduleSave()
        XCTAssertTrue(service.hasScheduledSave)
    }

    /// The service a test made, held where a teardown block registered
    /// before the service existed can look at it.
    @MainActor
    private final class MadeService {
        var service: ConfigService?
    }

    // MARK: - The Sources

    /// Every config service on a file of the test's own comes from
    /// `makeConfigService(fileURL:)`. One made by hand, whose teardown
    /// dropped nothing, could leave a save to fail after the sandbox was
    /// gone and be announced into another test. The files of all three test
    /// folders are read whole, so such a service fails here every time,
    /// however it is spelled (`serviceMakings(in:)`), rather than in another
    /// test now and then. This file and the helper's own are the two that
    /// may make one.
    func testEveryOtherConfigServiceComesFromTheHelper() throws {
        let repository = AppSourceFile.folder.deletingLastPathComponent()
        // The Mac's tests, and the iPhone's two bundles of a few files each.
        let folders = [("TextMouthProductionTests", 51), ("TextMouthiOSTests", 1), ("TextMouthiOSUITests", 1)]
        let allowed = ["ConfigTestSupport.swift", "ConfigTestWorldTeardownTests.swift"]
        var madeByHand: [String] = []
        for (folder, fewest) in folders {
            let sources = try AppSourceFile.all(in: repository.appendingPathComponent(folder, isDirectory: true), atLeast: fewest)
            for source in sources where !allowed.contains(source.name) {
                madeByHand += try Self.serviceMakings(in: source.text).map { "\(folder)/\(source.path):\($0)" }
            }
        }
        XCTAssertEqual(
            madeByHand,
            [],
            "make each config service with makeConfigService(fileURL:), whose teardown drops its waiting save"
        )
    }

    /// The guard finds a service made on a file however Swift spells it:
    /// with `.init`, with spaces, or with the argument on a line of its own,
    /// each counted on the line the making begins; and not one in a comment,
    /// another type's name ending in ConfigService, the shared service, one
    /// that follows the data directory, or the helper. The sample is written
    /// with a stand-in for the type's name, so this file holds no making for
    /// the guard to find.
    func testTheGuardFindsEveryWayOfMakingAService() throws {
        let sample = """
        let a = SERVICE(fileURL: file)
        let b = SERVICE.init(fileURL: file)
        let c = SERVICE (fileURL : file)
        let d = SERVICE(
            fileURL: file
        )
        // SERVICE(fileURL: in a comment)
        /// A doc comment naming SERVICE(fileURL:).
        let e = MirrorSERVICE(fileURL: file)
        let f = SERVICE.shared
        let g = SERVICE(fileOperations: counter.operations)
        let h = makeConfigService(fileURL: file)
        let i = make() // SERVICE(fileURL: after code)
        """.replacingOccurrences(of: "SERVICE", with: "Config" + "Service")

        XCTAssertEqual(try Self.serviceMakings(in: sample), [1, 2, 3, 4])
    }

    /// The lines, counted from 1, on which `text` makes a ConfigService on a
    /// file: `ConfigService(fileURL:` or `ConfigService.init(fileURL:`, with
    /// any spaces or line breaks between the parts, each counted on the line
    /// where it begins. One after `//` on its line is in a comment and is
    /// passed over.
    private static func serviceMakings(in text: String) throws -> [Int] {
        guard text.contains("ConfigService") else { return [] }
        // The name must start the word: `makeConfigService(fileURL:` and
        // `MirrorConfigService(fileURL:` are not it.
        let making = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])ConfigService\s*(?:\.init)?\s*\(\s*fileURL\s*:"#)
        let whole = text as NSString
        return making.matches(in: text, range: NSRange(location: 0, length: whole.length)).compactMap { match in
            let linesBefore = whole.substring(to: match.range.location).components(separatedBy: "\n")
            guard let lineSoFar = linesBefore.last, !lineSoFar.contains("//") else { return nil }
            return linesBefore.count
        }
    }

    // MARK: - Waiting

    /// Runs the main run loop for `seconds`, so a save waiting on its delay
    /// gets its turn. Every wait here is bounded.
    private func spin(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Whether `condition` becomes true within five seconds.
    private func eventually(_ condition: () -> Bool) -> Bool {
        waitUntil(timeout: 5, condition)
    }
}
