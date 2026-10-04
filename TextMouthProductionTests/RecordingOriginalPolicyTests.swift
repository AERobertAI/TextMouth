import os
import XCTest
@testable import TextMouth

/// What happens to a recording's original take (FR04): kept for good,
/// never kept, or kept for some days after the book's audio was last made
/// from it, one day until the user picks another; a book's own policy wins
/// over the global one. The sweep that applies it deletes exactly the takes
/// whose time is up, strikes them from their records, touches nothing a
/// record does not list, and leaves a record only in the cloud for later.
/// Every test runs on a clock of its own.
final class RecordingOriginalPolicyTests: XCTestCase {

    /// When the takes in these tests were saved.
    private static let saved = Date(timeIntervalSince1970: 1_791_000_000)
    /// One day, in seconds.
    private static let day: TimeInterval = 24 * 60 * 60

    // MARK: - The Policy

    /// Until the user picks another, an original take is deleted one day
    /// after saving.
    func testTheStandardPolicyKeepsATakeForOneDay() {
        XCTAssertEqual(AudioOriginalPolicy.standard, .deleteAfter(days: 1))
        XCTAssertEqual(SettingsPolicy.recordingOriginalPolicy.defaultValue, .deleteAfterDays)
        XCTAssertEqual(SettingsPolicy.recordingOriginalDays.defaultValue, 1)
        XCTAssertEqual(SettingsPolicy.recordingOriginalDays.range, 1...365)
    }

    /// Keep never deletes; delete deletes at once; after some days deletes
    /// at exactly that many days, not a moment before.
    func testEachPolicySaysWhenATakeIsDue() {
        let saved = Self.saved
        XCTAssertNil(AudioOriginalPolicy.keep.deletionDate(lastEdited: saved))
        XCTAssertFalse(AudioOriginalPolicy.keep.isDue(lastEdited: saved, now: saved.addingTimeInterval(1_000 * Self.day)))
        XCTAssertTrue(AudioOriginalPolicy.delete.isDue(lastEdited: saved, now: saved))
        let threeDays = AudioOriginalPolicy.deleteAfter(days: 3)
        XCTAssertEqual(threeDays.deletionDate(lastEdited: saved), saved.addingTimeInterval(3 * Self.day))
        XCTAssertFalse(threeDays.isDue(lastEdited: saved, now: saved.addingTimeInterval(3 * Self.day - 1)))
        XCTAssertTrue(threeDays.isDue(lastEdited: saved, now: saved.addingTimeInterval(3 * Self.day)))
    }

    /// A choice and a number of days make the policy, and the policy gives
    /// them back.
    func testAChoiceAndDaysMakeThePolicy() {
        XCTAssertEqual(AudioOriginalPolicy(choice: .keep, days: 9), .keep)
        XCTAssertEqual(AudioOriginalPolicy(choice: .delete, days: 9), .delete)
        XCTAssertEqual(AudioOriginalPolicy(choice: .deleteAfterDays, days: 9), .deleteAfter(days: 9))
        XCTAssertEqual(AudioOriginalPolicy.deleteAfter(days: 9).choice, .deleteAfterDays)
        XCTAssertEqual(AudioOriginalPolicy.Choice.allCases.map(\.rawValue), ["keep", "delete", "deleteAfterDays"])
    }

    /// A book's record holds its own policy by choice and days, a number of
    /// days out of range brought within it, and no days for keep or delete.
    func testABooksPolicyIsWrittenByItsChoiceAndDays() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(
            String(decoding: try encoder.encode(AudioOriginalPolicy.deleteAfter(days: 3)), as: UTF8.self),
            #"{"choice":"deleteAfterDays","days":3}"#
        )
        XCTAssertEqual(String(decoding: try encoder.encode(AudioOriginalPolicy.keep), as: UTF8.self), #"{"choice":"keep"}"#)

        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> AudioOriginalPolicy {
            try decoder.decode(AudioOriginalPolicy.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"choice":"delete"}"#), .delete)
        XCTAssertEqual(try decode(#"{"choice":"deleteAfterDays","days":900}"#), .deleteAfter(days: 365))
        XCTAssertEqual(try decode(#"{"choice":"deleteAfterDays"}"#), .deleteAfter(days: 1))
        XCTAssertThrowsError(try decode(#"{"choice":"forever"}"#))
    }

    /// The global policy is kept in the store as a choice and a number of
    /// days; anything unreadable there reads as the standard policy, and a
    /// choice of keep or delete leaves the days for later.
    func testTheGlobalPolicyIsKeptInTheStore() {
        let store = makeSandboxedPreferences("recording-policy")
        XCTAssertEqual(AudioOriginalPolicy.choicePreference.key, "recordingOriginalPolicy")
        XCTAssertEqual(AudioOriginalPolicy.daysPreference.key, "recordingOriginalDays")
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .standard)

        AudioOriginalPolicy.saveGlobal(.deleteAfter(days: 7), in: store)
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .deleteAfter(days: 7))
        AudioOriginalPolicy.saveGlobal(.keep, in: store)
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .keep)
        XCTAssertEqual(AudioOriginalPolicy.daysPreference.read(from: store), 7, "keep forgot the days")

        store.set("forever", forKey: "recordingOriginalPolicy")
        store.set(-4, forKey: "recordingOriginalDays")
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .deleteAfter(days: 1))
        XCTAssertTrue(RecordingPreferences.keys.contains("recordingOriginalPolicy"))
        XCTAssertTrue(RecordingPreferences.keys.contains("recordingOriginalDays"))
    }

    // MARK: - The Sweep

    /// Under keep, no take is ever deleted.
    func testKeepNeverDeletesATake() throws {
        let package = try makePackage(policy: nil)

        let result = RecordingTakeSweep.sweep(packages: [package], global: .keep, now: Self.saved.addingTimeInterval(1_000 * Self.day))

        XCTAssertEqual(result, RecordingTakeSweep.Result())
        XCTAssertTrue(hasTake(package))
        XCTAssertNotNil(try BookOrigin.load(fromPackage: package)?.originalTake)
    }

    /// Under delete, a take is deleted at the first sweep.
    func testDeleteRemovesATakeAtOnce() throws {
        let package = try makePackage(policy: nil)

        let result = RecordingTakeSweep.sweep(packages: [package], global: .delete, now: Self.saved)

        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(hasTake(package))
    }

    /// After some days, a take stays until its day comes, then goes; its
    /// record says it is gone, and the book's own audio stays.
    func testATakeIsKeptUntilItsDayComes() throws {
        let package = try makePackage(policy: nil)

        let early = RecordingTakeSweep.sweep(packages: [package], global: .standard, now: Self.saved.addingTimeInterval(Self.day - 60))
        XCTAssertEqual(early.removed, 0)
        XCTAssertTrue(hasTake(package))

        let due = RecordingTakeSweep.sweep(packages: [package], global: .standard, now: Self.saved.addingTimeInterval(Self.day))
        XCTAssertEqual(due.removed, 1)
        XCTAssertFalse(hasTake(package))
        let origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        XCTAssertNil(origin.originalTake)
        XCTAssertEqual(origin.kind, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("Ridge Walk.m4a").path))

        // A second sweep finds nothing more to do.
        XCTAssertEqual(
            RecordingTakeSweep.sweep(packages: [package], global: .standard, now: Self.saved.addingTimeInterval(2 * Self.day)),
            RecordingTakeSweep.Result()
        )
    }

    /// A book's own policy wins over the global one, either way.
    func testABooksOwnPolicyWinsOverTheGlobalOne() throws {
        let kept = try makePackage(policy: .keep)
        let deleted = try makePackage(policy: .delete)

        let result = RecordingTakeSweep.sweep(packages: [kept, deleted], global: .deleteAfter(days: 1), now: Self.saved.addingTimeInterval(30 * Self.day))

        XCTAssertEqual(result.removed, 1)
        XCTAssertTrue(hasTake(kept))
        XCTAssertFalse(hasTake(deleted))
    }

    /// Only a take a record lists is ever deleted: a package without an
    /// origin record keeps a file of the same name, and a record listing no
    /// take is left as it is.
    func testOnlyATakeARecordListsIsDeleted() throws {
        let unrecorded = try makePackage(policy: nil, writesRecord: false)
        let noTake = try makePackage(policy: nil, keepsTake: false)

        let result = RecordingTakeSweep.sweep(packages: [unrecorded, noTake], global: .delete, now: Self.saved)

        XCTAssertEqual(result, RecordingTakeSweep.Result())
        XCTAssertTrue(hasTake(unrecorded))
        XCTAssertNil(try BookOrigin.load(fromPackage: unrecorded))
    }

    /// A take already gone, deleted by hand, is struck from its record.
    func testATakeAlreadyGoneIsStruckFromTheRecord() throws {
        let package = try makePackage(policy: nil)
        try FileManager.default.removeItem(at: package.appendingPathComponent(BookOrigin.originalTakeFileName))

        let result = RecordingTakeSweep.sweep(packages: [package], global: .delete, now: Self.saved)

        XCTAssertEqual(result.removed, 1)
        XCTAssertNil(try BookOrigin.load(fromPackage: package)?.originalTake)
    }

    /// A record edited to name a file outside its package deletes nothing:
    /// the file stays, and the sweep counts a failure.
    func testATakeNamedOutsideItsPackageIsNeverDeleted() throws {
        let package = try makePackage(policy: nil)
        let outside = package.deletingLastPathComponent().appendingPathComponent("Keep Me.caf")
        try Data("outside".utf8).write(to: outside)
        var origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        origin.originalTake?.fileName = "../Keep Me.caf"
        try origin.save(toPackage: package)

        let result = RecordingTakeSweep.sweep(packages: [package], global: .delete, now: Self.saved)

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(hasTake(package))
        XCTAssertFalse(BookOrigin.isPlainFileName("../Keep Me.caf"))
        XCTAssertFalse(BookOrigin.isPlainFileName(".."))
        XCTAssertTrue(BookOrigin.isPlainFileName(BookOrigin.originalTakeFileName))
    }

    /// A package whose record is only in the cloud is left for a later
    /// sweep: nothing in it is read or deleted, and the others are swept.
    func testARecordOnlyInTheCloudIsLeftForLater() throws {
        let inCloud = try makePackage(policy: nil)
        let local = try makePackage(policy: nil)

        let result = RecordingTakeSweep.sweep(packages: [inCloud, local], global: .delete, now: Self.saved) { package in
            if package == inCloud { throw LocalBookFiles.downloadRefusal }
            return try BookOrigin.load(fromPackage: package)
        }

        XCTAssertEqual(result, RecordingTakeSweep.Result(removed: 1, leftInCloud: 1, failed: 0))
        XCTAssertTrue(hasTake(inCloud))
        XCTAssertFalse(hasTake(local))
    }

    /// The library sweeps its recordings in the background, as storage
    /// work, and says what it did: here, one take whose day has come.
    @MainActor
    func testTheLibrarySweepsItsRecordingsInTheBackground() throws {
        let folderPath = "Recording Sweep \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let package = try makePackage(policy: .deleteAfter(days: 1), in: folder)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        model.library.addBook(Book(
            title: "Ridge Walk",
            format: .audio,
            filePath: package.appendingPathComponent("Ridge Walk.m4a").path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        ))

        let swept = expectation(description: "the sweep finished")
        swept.assertForOverFulfill = false
        let outcome = SweepOutcome()
        model.sweepRecordingTakesInBackground(now: Self.saved.addingTimeInterval(2 * Self.day)) { result in
            outcome.set(result)
            swept.fulfill()
        }
        wait(for: [swept], timeout: 20)

        XCTAssertEqual(outcome.result?.removed, 1)
        XCTAssertFalse(hasTake(package))
    }

    // MARK: - config.json

    /// config.json carries the global policy by name: written as TextMouth
    /// keeps it, applied when edited, and a choice it does not know, or a
    /// number out of range, read as "keep the choice" and "the nearest
    /// supported number".
    @MainActor
    func testThePolicyIsMirroredInConfigJSON() throws {
        let store = makeSandboxedPreferences("recording-policy-config")
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)

        var written = ConfigService.AppConfig()
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.recordingOriginalPolicy, "deleteAfterDays")
        XCTAssertEqual(written.recordingOriginalDays, 1)

        settings.applyConfigChanges(try config(#"{"recordingOriginalPolicy": "keep", "recordingOriginalDays": 30}"#))
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .keep)
        XCTAssertEqual(AudioOriginalPolicy.daysPreference.read(from: store), 30)

        let unusable = try config(#"{"recordingOriginalPolicy": "forever", "recordingOriginalDays": 1000}"#)
        XCTAssertEqual(unusable.recordingOriginalPolicy, "")
        XCTAssertEqual(unusable.recordingOriginalDays, 365)
        settings.applyConfigChanges(unusable)
        XCTAssertEqual(AudioOriginalPolicy.choicePreference.read(from: store), .keep)
        XCTAssertEqual(AudioOriginalPolicy.daysPreference.read(from: store), 365)

        settings.applyConfigChanges(try config("{}"))
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .keep, "a file without the fields changed the policy")
    }

    // MARK: - Helpers

    /// A recording's package in a folder of this test's own, or in `folder`:
    /// its audio, its take unless `keepsTake` is false, and its origin
    /// record unless `writesRecord` is false, the take saved at `saved`
    /// under the book's own `policy`.
    private func makePackage(
        policy: AudioOriginalPolicy?,
        keepsTake: Bool = true,
        writesRecord: Bool = true,
        in folder: URL? = nil
    ) throws -> URL {
        let parent = try folder ?? RecordingAudioFixtures.makeTakesFolder(for: self)
        let package = parent.appendingPathComponent("Ridge Walk-Unknown-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: package.appendingPathComponent("Ridge Walk.m4a"))
        try Data("take".utf8).write(to: package.appendingPathComponent(BookOrigin.originalTakeFileName))
        if writesRecord {
            try BookOrigin(
                kind: .recording,
                recordedAt: Self.saved.addingTimeInterval(-120),
                duration: 95,
                inputDeviceName: "MacBook Air Microphone",
                originalTake: keepsTake
                    ? BookOrigin.OriginalTake(fileName: BookOrigin.originalTakeFileName, lastEditedAt: Self.saved, policyOverride: policy)
                    : nil
            ).save(toPackage: package)
        }
        return package
    }

    /// Whether `package` still holds its original take.
    private func hasTake(_ package: URL) -> Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent(BookOrigin.originalTakeFileName).path)
    }

    /// Decodes config.json text as `ConfigService` does.
    private func config(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }
}

/// What a background sweep reported, handed from its queue to the test.
private final class SweepOutcome: Sendable {
    /// The result, behind a lock.
    private let stored = OSAllocatedUnfairLock<RecordingTakeSweep.Result?>(initialState: nil)

    /// The result, once reported.
    var result: RecordingTakeSweep.Result? {
        stored.withLock { $0 }
    }

    /// Keeps `result`.
    func set(_ result: RecordingTakeSweep.Result) {
        stored.withLock { $0 = result }
    }
}
