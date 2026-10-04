import os
import SwiftUI
import XCTest
@testable import TextMouth

/// What happens to the original audio of recordings and edited audiobooks
/// (FR04): kept for good, never kept, or kept for some days after the last
/// edit, one day until the user picks another; a book's own policy wins over
/// the global one. The sweep that applies it deletes exactly the originals
/// whose time is up and that nothing can still need: never one whose edits
/// wait to be rendered from it, never while its book is open in a reader or
/// its audio is being edited or rendered, never one a history it cannot
/// trust lists, and never one only a record in the cloud describes. Every
/// test runs on a clock of its own.
final class AudioOriginalPolicyTests: XCTestCase {

    /// When the originals in these tests were last edited.
    private static let saved = Date(timeIntervalSince1970: 1_791_000_000)
    /// One day, in seconds.
    private static let day: TimeInterval = 24 * 60 * 60

    // MARK: - The Policy

    /// Until the user picks another, an original is deleted one day after
    /// the last edit.
    func testTheStandardPolicyKeepsAnOriginalForOneDay() {
        XCTAssertEqual(AudioOriginalPolicy.standard, .deleteAfter(days: 1))
        XCTAssertEqual(SettingsPolicy.recordingOriginalPolicy.defaultValue, .deleteAfterDays)
        XCTAssertEqual(SettingsPolicy.recordingOriginalDays.defaultValue, 1)
        XCTAssertEqual(SettingsPolicy.recordingOriginalDays.range, 1...365)
    }

    /// Keep never deletes; delete deletes at once; after some days deletes
    /// at exactly that many days, not a moment before.
    func testEachPolicySaysWhenAnOriginalIsDue() {
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
    /// days, under the names it had when only recordings kept originals;
    /// anything unreadable there reads as the standard policy, and a choice
    /// of keep or delete leaves the days for later.
    func testTheGlobalPolicyIsKeptInTheStore() {
        let store = makeSandboxedPreferences("original-policy")
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
        XCTAssertEqual(AudioEditingPreferences.keys, ["recordingOriginalPolicy", "recordingOriginalDays"])
        XCTAssertFalse(RecordingPreferences.keys.contains("recordingOriginalPolicy"))
    }

    // MARK: - A Recording's Take

    /// Under keep, no take is ever deleted.
    func testKeepNeverDeletesATake() throws {
        let package = try makeRecordingPackage(policy: nil)

        let result = sweep([package], global: .keep, now: Self.saved.addingTimeInterval(1_000 * Self.day))

        XCTAssertEqual(result, AudioOriginalSweep.Result())
        XCTAssertTrue(hasTake(package))
        XCTAssertNotNil(try BookOrigin.load(fromPackage: package)?.originalTake)
    }

    /// Under delete, a take is deleted at the first sweep.
    func testDeleteRemovesATakeAtOnce() throws {
        let package = try makeRecordingPackage(policy: nil)

        let result = sweep([package], global: .delete, now: Self.saved)

        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(hasTake(package))
    }

    /// After some days, a take stays until its day comes, then goes; its
    /// record says it is gone, and the book's own audio stays. A recording
    /// never edited keeps its record in its origin record throughout.
    func testATakeIsKeptUntilItsDayComes() throws {
        let package = try makeRecordingPackage(policy: nil)

        let early = sweep([package], global: .standard, now: Self.saved.addingTimeInterval(Self.day - 60))
        XCTAssertEqual(early.removed, 0)
        XCTAssertTrue(hasTake(package))

        let due = sweep([package], global: .standard, now: Self.saved.addingTimeInterval(Self.day))
        XCTAssertEqual(due.removed, 1)
        XCTAssertFalse(hasTake(package))
        let origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        XCTAssertNil(origin.originalTake)
        XCTAssertEqual(origin.kind, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("Ridge Walk.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioEditPackage.historyURL(in: package).path))

        // A second sweep finds nothing more to do.
        XCTAssertEqual(sweep([package], global: .standard, now: Self.saved.addingTimeInterval(2 * Self.day)), AudioOriginalSweep.Result())
    }

    /// A book's own policy wins over the global one, either way.
    func testABooksOwnPolicyWinsOverTheGlobalOne() throws {
        let kept = try makeRecordingPackage(policy: .keep)
        let deleted = try makeRecordingPackage(policy: .delete)

        let result = sweep([kept, deleted], global: .deleteAfter(days: 1), now: Self.saved.addingTimeInterval(30 * Self.day))

        XCTAssertEqual(result.removed, 1)
        XCTAssertTrue(hasTake(kept))
        XCTAssertFalse(hasTake(deleted))
    }

    /// Only a take a record lists is ever deleted: a package without an
    /// origin record keeps a file of the same name, and a record listing no
    /// take is left as it is.
    func testOnlyATakeARecordListsIsDeleted() throws {
        let unrecorded = try makeRecordingPackage(policy: nil, writesRecord: false)
        let noTake = try makeRecordingPackage(policy: nil, keepsTake: false)

        let result = sweep([unrecorded, noTake], global: .delete, now: Self.saved)

        XCTAssertEqual(result, AudioOriginalSweep.Result())
        XCTAssertTrue(hasTake(unrecorded))
        XCTAssertNil(try BookOrigin.load(fromPackage: unrecorded))
    }

    /// A take already gone, deleted by hand, is struck from its record.
    func testATakeAlreadyGoneIsStruckFromTheRecord() throws {
        let package = try makeRecordingPackage(policy: nil)
        try FileManager.default.removeItem(at: package.appendingPathComponent(BookOrigin.originalTakeFileName))

        let result = sweep([package], global: .delete, now: Self.saved)

        XCTAssertEqual(result.removed, 1)
        XCTAssertNil(try BookOrigin.load(fromPackage: package)?.originalTake)
    }

    /// A record edited to name a file outside its package deletes nothing:
    /// the file stays, and the sweep counts a failure.
    func testATakeNamedOutsideItsPackageIsNeverDeleted() throws {
        let package = try makeRecordingPackage(policy: nil)
        let outside = package.deletingLastPathComponent().appendingPathComponent("Keep Me.caf")
        try Data("outside".utf8).write(to: outside)
        var origin = try XCTUnwrap(try BookOrigin.load(fromPackage: package))
        origin.originalTake?.fileName = "../Keep Me.caf"
        try origin.save(toPackage: package)

        let result = sweep([package], global: .delete, now: Self.saved)

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
        let inCloud = try makeRecordingPackage(policy: nil)
        let local = try makeRecordingPackage(policy: nil)

        let result = sweep([inCloud, local], global: .delete, now: Self.saved, loadOrigin: { package in
            if package == inCloud { throw LocalBookFiles.downloadRefusal }
            return try BookOrigin.load(fromPackage: package)
        })

        XCTAssertEqual(result, AudioOriginalSweep.Result(removed: 1, leftInCloud: 1))
        XCTAssertTrue(hasTake(inCloud))
        XCTAssertFalse(hasTake(local))
    }

    // MARK: - An Edited Audiobook's Original

    /// An imported audiobook's original, a copy of its file from before its
    /// first edit, is deleted when its day comes, once the book's audio
    /// holds its edits: the history then keeps the edits for reference, and
    /// says undo stops at them.
    func testAnEditedBooksOriginalIsDeletedWhenItsDayComes() throws {
        let package = try makeEditedPackage(policy: nil, rendered: true)
        let original = try XCTUnwrap(editList(in: package).original)

        let early = sweep([package], bookFile: "Canal Survey.m4b", global: .standard, now: Self.saved.addingTimeInterval(Self.day - 1))
        XCTAssertEqual(early.removed, 0)

        let due = sweep([package], bookFile: "Canal Survey.m4b", global: .standard, now: Self.saved.addingTimeInterval(Self.day))

        XCTAssertEqual(due.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent(original.file).path))
        let list = try editList(in: package)
        XCTAssertNil(list.original)
        XCTAssertEqual(list.originalDeletedAt, Self.saved.addingTimeInterval(Self.day))
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertFalse(list.canUndo)
        XCTAssertEqual(list.undoLimit, .originalDeleted(Self.saved.addingTimeInterval(Self.day)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("Canal Survey.m4b").path))
    }

    /// An original whose edits wait to be rendered from it stays, however
    /// due: only the original can make them.
    func testAnOriginalStaysWhileEditsWaitToBeRendered() throws {
        let package = try makeEditedPackage(policy: nil, rendered: false)

        let result = sweep([package], bookFile: "Canal Survey.m4b", global: .delete, now: Self.saved.addingTimeInterval(30 * Self.day))

        XCTAssertEqual(result, AudioOriginalSweep.Result())
        XCTAssertNotNil(try editList(in: package).original)
    }

    /// An original stays while its book is in use: open in a reader, or its
    /// audio being edited or rendered.
    func testAnOriginalStaysWhileItsBookIsInUse() throws {
        let package = try makeEditedPackage(policy: nil, rendered: true)

        let busy = sweep([package], bookFile: "Canal Survey.m4b", global: .delete, now: Self.saved, isInUse: { _ in true })
        XCTAssertEqual(busy, AudioOriginalSweep.Result(inUse: 1))
        XCTAssertNotNil(try editList(in: package).original)

        let idle = sweep([package], bookFile: "Canal Survey.m4b", global: .delete, now: Self.saved)
        XCTAssertEqual(idle.removed, 1)
    }

    /// A book's own policy, kept in its edit history, wins over the global
    /// one.
    func testABooksPolicyInItsHistoryWins() throws {
        let kept = try makeEditedPackage(policy: .keep, rendered: true)
        let deleted = try makeEditedPackage(policy: .delete, rendered: true)

        let result = sweep([kept, deleted], bookFile: "Canal Survey.m4b", global: .deleteAfter(days: 365), now: Self.saved)

        XCTAssertEqual(result.removed, 1)
        XCTAssertNotNil(try editList(in: kept).original)
        XCTAssertNil(try editList(in: deleted).original)
    }

    /// A history the sweep cannot trust, damaged or from a later version,
    /// deletes no original.
    func testAHistoryTheSweepCannotTrustIsLeftAlone() throws {
        let damaged = try makeEditedPackage(policy: nil, rendered: true)
        let original = try XCTUnwrap(editList(in: damaged).original)
        try Data("{ not json".utf8).write(to: AudioEditPackage.historyURL(in: damaged))
        let newer = try makeEditedPackage(policy: nil, rendered: true)
        let newerOriginal = try XCTUnwrap(editList(in: newer).original)
        try Data(#"{"version":7}"#.utf8).write(to: AudioEditPackage.historyURL(in: newer))

        let result = sweep([damaged, newer], bookFile: "Canal Survey.m4b", global: .delete, now: Self.saved)

        XCTAssertEqual(result, AudioOriginalSweep.Result())
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.appendingPathComponent(original.file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.appendingPathComponent(newerOriginal.file).path))
    }

    // MARK: - The Library

    /// The library sweeps its audiobooks in the background, as storage work,
    /// and says what it did: here, one take whose day has come.
    @MainActor
    func testTheLibrarySweepsItsAudiobooksInTheBackground() throws {
        let (model, book, package) = try makeLibraryWithRecording(policy: .deleteAfter(days: 1))

        let result = sweepInBackground(model, now: Self.saved.addingTimeInterval(2 * Self.day))

        XCTAssertEqual(result?.removed, 1)
        XCTAssertFalse(hasTake(package))
        XCTAssertEqual(model.bookByID(book.id)?.id, book.id)
    }

    /// The library never deletes the original of a book open in a reader;
    /// once the reader closes, the next sweep does.
    @MainActor
    func testTheLibraryNeverDeletesTheOriginalOfABookOpenInAReader() throws {
        let (model, book, package) = try makeLibraryWithRecording(policy: .delete)
        model.openBookIDs = [book.id]

        let whileOpen = sweepInBackground(model, now: Self.saved)
        XCTAssertEqual(whileOpen?.inUse, 1)
        XCTAssertTrue(hasTake(package))

        model.openBookIDs = []
        let afterClosing = sweepInBackground(model, now: Self.saved)
        XCTAssertEqual(afterClosing?.removed, 1)
        XCTAssertFalse(hasTake(package))
    }

    /// The library never deletes the original of a book whose audio is
    /// being edited or rendered.
    @MainActor
    func testTheLibraryNeverDeletesTheOriginalOfABookBeingEdited() throws {
        let (model, book, package) = try makeLibraryWithRecording(policy: .delete)
        model.audioEditActivity.beginUse(of: book.id)
        model.audioEditActivity.beginUse(of: book.id)

        XCTAssertEqual(sweepInBackground(model, now: Self.saved)?.inUse, 1)
        model.audioEditActivity.endUse(of: book.id)
        XCTAssertEqual(sweepInBackground(model, now: Self.saved)?.inUse, 1, "one use is still under way")
        XCTAssertTrue(hasTake(package))

        model.audioEditActivity.endUse(of: book.id)
        XCTAssertEqual(sweepInBackground(model, now: Self.saved)?.removed, 1)
    }

    /// A book's own policy is set through the library, and "don't keep" then
    /// deletes the take at the next sweep: the one the change starts, or
    /// this test's, whichever comes first.
    @MainActor
    func testABooksOwnPolicyIsSetThroughTheLibrary() async throws {
        let (model, book, package) = try makeLibraryWithRecording(policy: .keep)

        try await model.setAudioOriginalPolicy(.delete, forBook: book.id)

        // Read through the store, which finds the policy in the origin record
        // before the take is deleted and in edits.json after.
        guard case .found(let history, _) = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Ridge Walk.m4a") else {
            return XCTFail("the history could not be read")
        }
        XCTAssertEqual(history.policyOverride, .delete)
        let result = await sweepInBackgroundAsync(model, now: Self.saved)
        XCTAssertFalse(hasTake(package), "the take outlived its book's own policy: \(String(describing: result))")

        do {
            try await model.setAudioOriginalPolicy(.keep, forBook: UUID())
            XCTFail("a book not in the library took a policy")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .bookNotInLibrary)
        }
    }

    // MARK: - config.json

    /// config.json carries the global policy by name: written as TextMouth
    /// keeps it, applied when edited, and a choice it does not know, or a
    /// number out of range, read as "keep the choice" and "the nearest
    /// supported number".
    @MainActor
    func testThePolicyIsMirroredInConfigJSON() throws {
        let store = makeSandboxedPreferences("original-policy-config")
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

    // MARK: - Storage Settings' Audio Editing Group

    /// The policy picker names each choice, explains them for recordings and
    /// edited audiobooks alike, and follows a change made anywhere, as
    /// config.json makes one; the days stepper shows only for a choice of
    /// days, with its own label.
    @MainActor
    func testTheAudioEditingGroupIsLabelledAndFollowsTheStore() throws {
        let store = makeSandboxedPreferences("audio-editing-settings")
        XCTAssertEqual(AudioOriginalPolicy.Choice.allCases.map(AudioEditingSettingsWording.choiceTitle), [
            "Keep", "Don't keep", "Keep for a number of days",
        ])
        XCTAssertEqual(
            AudioEditingSettingsWording.explanation(.deleteAfter(days: 1)),
            "Each recording and edited audiobook keeps its original audio for 1 day after it was saved or last "
                + "edited; then the original is deleted."
        )
        XCTAssertEqual(
            AudioEditingSettingsWording.explanation(.delete),
            "No original audio is kept: edits change a book's audio in place, and saved edits can't be undone."
        )
        let model = AudioEditingSettingsModel(store: store)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        AudioOriginalPolicy.saveGlobal(.deleteAfter(days: 3), in: store)
        XCTAssertGreaterThan(changes, 0, "a change made in the store was not shown")
        XCTAssertEqual(model.days, 3)
        model.choice = .keep
        XCTAssertEqual(AudioOriginalPolicy.global(in: store), .keep)

        try skipUnlessHostedWindowsExposeAccessibility()
        model.choice = .deleteAfterDays
        let section = Form { AudioEditingSettingsSection(store: store) }
        try withHostedView(section, size: NSSize(width: 600, height: 400), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty && !self.descendants(of: $0, as: NSStepper.self).isEmpty
        }) { hosting in
            let controls = accessibleControls(in: hosting)
            let picker = try XCTUnwrap(
                controls.first { $0.label == AudioEditingSettingsWording.policyLabel },
                "\(controls.map(\.label))"
            )
            XCTAssertEqual(picker.hint, AudioEditingSettingsWording.policyHint)
            let stepper = try XCTUnwrap(
                controls.first { $0.label == AudioEditingSettingsWording.daysLabel },
                "\(controls.map(\.label))"
            )
            XCTAssertEqual(stepper.valueDescription, "3 days")
        }
    }

    // MARK: - Helpers

    /// What sweeping `packages` at `now` under `global` does, each package
    /// standing for a book of its own whose file is `bookFile`, with the
    /// books `isInUse` names in use and origin records read by `loadOrigin`.
    private func sweep(
        _ packages: [URL],
        bookFile: String = "Ridge Walk.m4a",
        global: AudioOriginalPolicy,
        now: Date,
        isInUse: (UUID) -> Bool = { _ in false },
        loadOrigin: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:)
    ) -> AudioOriginalSweep.Result {
        AudioOriginalSweep.sweep(
            packages: packages.map { AudioOriginalSweep.Package(bookID: UUID(), url: $0, bookFile: bookFile) },
            global: global,
            now: now,
            isInUse: isInUse,
            loadOrigin: loadOrigin
        )
    }

    /// What `model`'s background sweep at `now` reported, waiting for it.
    @MainActor
    private func sweepInBackground(_ model: LibraryViewModel, now: Date) -> AudioOriginalSweep.Result? {
        let swept = expectation(description: "the sweep finished")
        swept.assertForOverFulfill = false
        let outcome = SweepOutcome()
        model.sweepAudioOriginalsInBackground(now: now) { result in
            outcome.set(result)
            swept.fulfill()
        }
        wait(for: [swept], timeout: 20)
        return outcome.result
    }

    /// `sweepInBackground(_:now:)` for an asynchronous test.
    @MainActor
    private func sweepInBackgroundAsync(_ model: LibraryViewModel, now: Date) async -> AudioOriginalSweep.Result? {
        let swept = expectation(description: "the sweep finished")
        swept.assertForOverFulfill = false
        let outcome = SweepOutcome()
        model.sweepAudioOriginalsInBackground(now: now) { result in
            outcome.set(result)
            swept.fulfill()
        }
        await fulfillment(of: [swept], timeout: 20)
        return outcome.result
    }

    /// A library of one recording, its package in a folder of the sandbox's
    /// library of this test's own, its take saved at `saved` under the
    /// book's own `policy`.
    @MainActor
    private func makeLibraryWithRecording(policy: AudioOriginalPolicy?) throws -> (LibraryViewModel, Book, URL) {
        let folderPath = "Original Sweep \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let package = try makeRecordingPackage(policy: policy, in: folder)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let book = Book(
            title: "Ridge Walk",
            format: .audio,
            filePath: package.appendingPathComponent("Ridge Walk.m4a").path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        model.library.addBook(book)
        return (model, book, package)
    }

    /// A recording's package in a folder of this test's own, or in `folder`:
    /// its audio, its take unless `keepsTake` is false, and its origin
    /// record unless `writesRecord` is false, the take saved at `saved`
    /// under the book's own `policy`.
    private func makeRecordingPackage(
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

    /// An imported audiobook's package in a folder of this test's own:
    /// "Canal Survey.m4b", whose bytes stand in for audio, its original kept
    /// under the history's folder, and a history of one cut made at `saved`,
    /// rendered into the book's file then when `rendered`, under the book's
    /// own `policy`.
    private func makeEditedPackage(policy: AudioOriginalPolicy?, rendered: Bool) throws -> URL {
        let parent = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let package = parent.appendingPathComponent("Canal Survey-Unknown-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("survey audio".utf8).write(to: package.appendingPathComponent("Canal Survey.m4b"))
        var list = AudioEditList(
            audioFile: "Canal Survey.m4b",
            original: try AudioEditPackage.keepOriginal(ofAudioFile: "Canal Survey.m4b", inPackage: package, at: Self.saved)
        )
        let cut = list.record(.cut(AudioTimeRange(start: 1, end: 2)), at: Self.saved)
        if rendered {
            list.markRendered(entryIDs: [cut.id], at: Self.saved)
        }
        try AudioEditHistoryStore.write(
            AudioEditHistory(policyOverride: policy, files: [list]),
            source: .noRecord,
            toPackage: package,
            bookFile: "Canal Survey.m4b"
        )
        return package
    }

    /// The edit list of "Canal Survey.m4b" in `package`, as edits.json holds it.
    private func editList(in package: URL) throws -> AudioEditList {
        guard case .found(let history, _) = AudioEditHistoryStore.read(fromPackage: package, bookFile: "Canal Survey.m4b") else {
            throw AudioEditError.historyUnusable("unreadable in the test")
        }
        return try XCTUnwrap(history.list(for: "Canal Survey.m4b"))
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
    private let stored = OSAllocatedUnfairLock<AudioOriginalSweep.Result?>(initialState: nil)

    /// The result, once reported.
    var result: AudioOriginalSweep.Result? {
        stored.withLock { $0 }
    }

    /// Keeps `result`.
    func set(_ result: AudioOriginalSweep.Result) {
        stored.withLock { $0 = result }
    }
}
