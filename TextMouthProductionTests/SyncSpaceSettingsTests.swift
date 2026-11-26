import XCTest
@testable import TextMouth

/// A device's own choice of books and the days a book may stay unopened (FR45): the defaults of each device, how
/// the choice is stored and kept off every other device, the rule that counts the days, what is said after each
/// change, and the words. Each test names the behavior it pins and fails when that behavior is taken out.
@MainActor
final class SyncSpaceSettingsTests: XCTestCase {
    /// A time the tests start from, and one a person's change was made at.
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - What a device starts with

    /// The Mac keeps every book and removes nothing; the iPhone keeps the books opened or kept and removes the
    /// download of a book unopened for 7 days.
    func testEachDeviceStartsWithItsOwnDefaults() {
        let mac = SyncDeviceSettings.defaults(isPhone: false)
        XCTAssertEqual(mac.books, .allBooks)
        XCTAssertNil(mac.removeAfterDays)
        XCTAssertNil(mac.activeDays)

        let phone = SyncDeviceSettings.defaults(isPhone: true)
        XCTAssertEqual(phone.books, .openedOrKept)
        XCTAssertEqual(phone.removeAfterDays, 7)
        XCTAssertEqual(phone.activeDays, 7)
    }

    /// The days apply only under "Books you open or keep": under "All books" nothing is removed, whatever the days.
    func testTheDaysApplyOnlyUnderBooksYouOpenOrKeep() {
        var settings = SyncDeviceSettings(books: .allBooks, removeAfterDays: 7, removalsBeganAt: nil)
        XCTAssertNil(settings.activeDays)
        settings.books = .openedOrKept
        XCTAssertEqual(settings.activeDays, 7)
        settings.removeAfterDays = nil
        XCTAssertNil(settings.activeDays, "Off removes nothing")
    }

    /// The days are Off or 1 to 30: anything lower is Off, anything higher is 30.
    func testTheDaysAreHeldBetweenOffAndThirty() {
        XCTAssertNil(SyncDeviceSettings.clampedDays(nil))
        XCTAssertNil(SyncDeviceSettings.clampedDays(0))
        XCTAssertNil(SyncDeviceSettings.clampedDays(-3))
        XCTAssertEqual(SyncDeviceSettings.clampedDays(1), 1)
        XCTAssertEqual(SyncDeviceSettings.clampedDays(30), 30)
        XCTAssertEqual(SyncDeviceSettings.clampedDays(31), 30)
    }

    // MARK: - Where the choice is kept

    /// Both choices and the date round-trip through the preferences, and a device that chose nothing reads its defaults.
    func testTheChoicesRoundTripThroughThePreferences() {
        let store = makeSandboxedPreferences("sync-space")
        XCTAssertEqual(SyncDeviceSettings.read(from: store, isPhone: true), SyncDeviceSettings.defaults(isPhone: true))
        XCTAssertEqual(SyncDeviceSettings.read(from: store, isPhone: false), SyncDeviceSettings.defaults(isPhone: false))

        let chosen = SyncDeviceSettings(books: .openedOrKept, removeAfterDays: 12, removalsBeganAt: start)
        chosen.write(to: store)
        XCTAssertEqual(SyncDeviceSettings.read(from: store, isPhone: false), chosen)

        // Off is a choice that is read back as Off, not as the iPhone's 7 days.
        let off = SyncDeviceSettings(books: .openedOrKept, removeAfterDays: nil, removalsBeganAt: nil)
        off.write(to: store)
        XCTAssertNil(SyncDeviceSettings.read(from: store, isPhone: true).removeAfterDays)
    }

    /// Both settings and the date are this device's own: their keys are among the machine-local ones, so config.json
    /// never carries them to another device, and no setting of config.json has their name.
    func testTheSettingsAreMachineLocal() throws {
        let keys = [SyncPreferences.booksOnThisDevice.key, SyncPreferences.removeAfterDays.key, SyncPreferences.removalsBeganAt.key]
        for key in keys {
            XCTAssertTrue(SyncPreferences.keys.contains(key), key)
            XCTAssertTrue(ConfigService.AppConfig.Portability.localStoreKeys.contains(key), key)
            XCTAssertFalse(ConfigService.AppConfig.Portability.mirrored.contains { $0.storeKey == key }, key)
        }
    }

    // MARK: - Changing

    /// Changing from "All books" to the other choice removes nothing at once: the removal's days count from the
    /// change, so a book unopened for a year stays until the days have passed since.
    func testChangingFromAllBooksStartsTheDaysFromTheChange() {
        let all = SyncDeviceSettings(books: .allBooks, removeAfterDays: 7, removalsBeganAt: nil)
        let changed = all.changing(books: .openedOrKept, at: start)
        XCTAssertEqual(changed.books, .openedOrKept)
        XCTAssertEqual(changed.removalsBeganAt, start)
    }

    /// Turning the days on from Off starts them from then; changing them while on keeps the date; turning them off
    /// and on again starts them again.
    func testTheDateTheRemovalBeganFollowsItBeingOn() {
        let off = SyncDeviceSettings(books: .openedOrKept, removeAfterDays: nil, removalsBeganAt: nil)
        let on = off.changing(removeAfterDays: .some(7), at: start)
        XCTAssertEqual(on.removalsBeganAt, start)

        let later = start.addingTimeInterval(3 * SyncSpacePolicy.secondsInDay)
        let shorter = on.changing(removeAfterDays: .some(3), at: later)
        XCTAssertEqual(shorter.removalsBeganAt, start, "the removal was on already")

        let offAgain = shorter.changing(removeAfterDays: .some(nil), at: later)
        XCTAssertNil(offAgain.activeDays)
        let onAgain = offAgain.changing(removeAfterDays: .some(5), at: later)
        XCTAssertEqual(onAgain.removalsBeganAt, later)
    }

    /// A device on which the removal applies by default (the iPhone) notes the day it first looked, once, and never
    /// a day on a device where nothing applies.
    func testTheFirstLookNotesTheDayOnce() {
        let phone = SyncDeviceSettings.defaults(isPhone: true)
        let begun = phone.beginningRemovals(at: start)
        XCTAssertEqual(begun.removalsBeganAt, start)
        XCTAssertEqual(begun.beginningRemovals(at: start.addingTimeInterval(500)).removalsBeganAt, start, "noted once")
        XCTAssertNil(SyncDeviceSettings.defaults(isPhone: false).beginningRemovals(at: start).removalsBeganAt)
    }

    // MARK: - The days

    /// A book's days count from the latest of its opening, its last play, its files' arrival, and the day the removal
    /// began; the day the removal began holds a book never opened.
    func testTheDaysCountFromTheLatestUse() {
        let began = start
        let day = SyncSpacePolicy.secondsInDay
        XCTAssertEqual(SyncSpacePolicy.lastInUse(opened: nil, played: nil, arrived: nil, removalsBeganAt: began), began)
        XCTAssertEqual(
            SyncSpacePolicy.lastInUse(opened: began.addingTimeInterval(day), played: began.addingTimeInterval(3 * day), arrived: began.addingTimeInterval(2 * day), removalsBeganAt: began),
            began.addingTimeInterval(3 * day), "a play here counts"
        )
        XCTAssertEqual(
            SyncSpacePolicy.lastInUse(opened: began.addingTimeInterval(-40 * day), played: nil, arrived: began.addingTimeInterval(-50 * day), removalsBeganAt: began),
            began, "a book opened long ago still waits the days from the day the removal began"
        )
    }

    /// A book is due when the days have passed, to the second, and not before.
    func testABookIsDueWhenTheDaysHavePassed() {
        let used = start
        let week = 7 * SyncSpacePolicy.secondsInDay
        XCTAssertFalse(SyncSpacePolicy.isDue(lastInUse: used, days: 7, now: used.addingTimeInterval(week - 1)))
        XCTAssertTrue(SyncSpacePolicy.isDue(lastInUse: used, days: 7, now: used.addingTimeInterval(week)))
        XCTAssertTrue(SyncSpacePolicy.isDue(lastInUse: used, days: 1, now: used.addingTimeInterval(week)))
        XCTAssertFalse(SyncSpacePolicy.isDue(lastInUse: used, days: 30, now: used.addingTimeInterval(week)))
    }

    /// Across the change to summer time, and so across a change of time zone, the days are 24 hours each: seven
    /// calendar days that hold a 23-hour day are not yet seven days, and an hour later they are.
    func testTheDaysAreCountedInHoursNotByTheWallClock() throws {
        let format = ISO8601DateFormatter()
        let opened = try XCTUnwrap(format.date(from: "2026-03-01T12:00:00-05:00"))
        let sevenCalendarDays = try XCTUnwrap(format.date(from: "2026-03-08T12:00:00-04:00"))
        let anHourLater = try XCTUnwrap(format.date(from: "2026-03-08T13:00:00-04:00"))
        XCTAssertEqual(sevenCalendarDays.timeIntervalSince(opened), 167 * 3600)

        XCTAssertFalse(SyncSpacePolicy.isDue(lastInUse: opened, days: 7, now: sevenCalendarDays))
        XCTAssertTrue(SyncSpacePolicy.isDue(lastInUse: opened, days: 7, now: anHourLater))

        // The same instants named in another zone are the same instants: nothing depends on the zone.
        let inTokyo = try XCTUnwrap(format.date(from: "2026-03-09T02:00:00+09:00"))
        XCTAssertEqual(inTokyo, anHourLater)
        XCTAssertTrue(SyncSpacePolicy.isDue(lastInUse: opened, days: 7, now: inTokyo))
    }

    // MARK: - What is said

    /// The model says the state after each change, keeps it in the preferences, and says nothing when a choice is
    /// chosen again.
    func testTheModelSaysTheStateAfterEveryChange() {
        var said: [String] = []
        let store = makeSandboxedPreferences("sync-space-model")
        let model = SyncSpaceSettings(store: store, isPhone: false, now: { self.start }, announce: { said.append($0) })

        model.setBooks(.openedOrKept)
        model.setBooks(.openedOrKept)
        model.setRemoveAfterDays(7)
        model.setRemoveAfterDays(7)
        model.setRemoveAfterDays(nil)
        model.setBooks(.allBooks)

        XCTAssertEqual(said, [
            "Books you open or keep. Nothing is removed now.",
            "Removing downloads of books unopened for 7 days.",
            "Not removing the downloads of unopened books.",
            "All books. Books missing here download after the next sync.",
        ])
        XCTAssertEqual(SyncDeviceSettings.read(from: store, isPhone: false).books, .allBooks, "kept in the preferences")
        XCTAssertEqual(SyncSpaceSettings(store: store, isPhone: false).settings.books, .allBooks, "and read again at the next launch")
    }

    /// A step VoiceOver takes by adjusting the days is said once, by VoiceOver reading the new value: the model keeps the
    /// step and says nothing of its own; the control's own arrows still have the new state said.
    func testAStepVoiceOverAdjustsIsSaidOnce() {
        var said: [String] = []
        let model = SyncSpaceSettings(store: makeSandboxedPreferences("sync-space-step"), isPhone: true, now: { self.start }, announce: { said.append($0) })
        model.setRemoveAfterDays(SyncSpaceControls.step(7, by: 1), announcing: false)
        XCTAssertEqual(model.settings.removeAfterDays, 8)
        XCTAssertEqual(said, [], "VoiceOver reads the value; nothing is announced over it")
        XCTAssertEqual(SyncSpaceControls.value(of: model.settings.removeAfterDays), "8 days")
        model.setRemoveAfterDays(9)
        XCTAssertEqual(said, ["Removing downloads of books unopened for 9 days."])
    }

    /// Turning the removal on starts its days from the change, and the first look at a device whose removal is on
    /// by default says nothing, since nothing was chosen.
    func testTheModelCountsTheDaysFromTheChange() {
        var said: [String] = []
        let model = SyncSpaceSettings(store: makeSandboxedPreferences("sync-space-days"), isPhone: false, now: { self.start }, announce: { said.append($0) })
        model.setBooks(.openedOrKept)
        XCTAssertNil(model.settings.removalsBeganAt, "Off: the days do not run")
        model.setRemoveAfterDays(7)
        XCTAssertEqual(model.settings.removalsBeganAt, start)

        said = []
        let phone = SyncSpaceSettings(store: makeSandboxedPreferences("sync-space-phone"), isPhone: true, now: { self.start }, announce: { said.append($0) })
        phone.beginRemovalsIfNeeded()
        XCTAssertEqual(phone.settings.removalsBeganAt, start)
        XCTAssertEqual(said, [])
    }

    // MARK: - The words

    /// The settings' lines are pinned, and each control has a label and a hint.
    func testTheSettingsWordsArePinned() {
        XCTAssertEqual(SyncWording.booksOnDeviceLabel, "Books on this device")
        XCTAssertEqual(SyncWording.booksOnDeviceAll, "All books")
        XCTAssertEqual(SyncWording.booksOnDeviceOpenedOrKept, "Books you open or keep")
        XCTAssertEqual(SyncWording.booksOnDeviceHint, "Chooses whether this device downloads every book, or only the books you open or keep.")
        XCTAssertEqual(SyncWording.removeAfterLabel, "Remove unopened downloads after")
        XCTAssertEqual(SyncWording.removeAfterHint, "Removes a book's download from this device once you haven't opened it for this long. The book stays in iCloud Drive.")
        XCTAssertEqual(SyncWording.removeAfterValue(nil), "Off")
        XCTAssertEqual(SyncWording.removeAfterValue(7), "7 days")
    }

    /// Every refusal and result is a sentence, one for each kind, and the sentences differ where the advice does.
    func testTheRefusalsAreSaidInWords() {
        let cases: [(SyncRemovalRefusal, String)] = [
            (.notBackedUp, "TextMouth hasn't confirmed that iCloud Drive holds every file of this book, so its download stays. Try again in a moment."),
            (.notUploaded("x"), "TextMouth hasn't confirmed that iCloud Drive holds every file of this book, so its download stays. Try again in a moment."),
            (.changedHere("x"), "This book has changes that iCloud Drive doesn't hold yet, so its download stays."),
            (.doesNotMatch("x"), "The copy in iCloud Drive doesn't match this book, so its download stays."),
            (.offline, "TextMouth can't check the copy in iCloud Drive while this Mac is offline, so the download stays."),
            (.needsDownload, "To free this book, TextMouth first checks its copy in iCloud Drive. That needs room for one more copy of the book, and Wi-Fi on cellular data. Its download stays for now."),
            (.needsRoom, "To free this book, TextMouth first checks its copy in iCloud Drive. That needs room for one more copy of the book, and Wi-Fi on cellular data. Its download stays for now."),
            (.couldNotRemove("x"), "TextMouth couldn't remove all of this book's files."),
            (.busy, "The book is in use, so its download can't be removed."),
            (.nothingToRemove, "None of the selected books has a download to remove."),
        ]
        for (refusal, words) in cases {
            XCTAssertEqual(SyncWording.removalRefusal(refusal, isPhone: false), words, "\(refusal)")
            XCTAssertFalse(refusal.logReason.isEmpty)
        }
        XCTAssertEqual(
            SyncWording.removalRefusal(.offline, isPhone: true),
            "TextMouth can't check the copy in iCloud Drive while this iPhone is offline, so the download stays."
        )
        XCTAssertEqual(
            BookCloudError.keptOnAllDevices.explanation(in: nil, isPhone: false),
            "The book is kept on all devices, so its download can't be removed. Choose Stop Keeping on All Devices first."
        )
        XCTAssertEqual(BookCloudError.bookInUse.explanation(in: nil, isPhone: false), "The book is in use, so its download can't be removed.")
    }

    /// One summary says what a sweep removed, counting books and days, and where the books stay.
    func testTheSummaryOfARemovalIsOneSentence() {
        XCTAssertEqual(
            SyncWording.announceRemovedUnopened(books: 3, days: 7),
            "Removed downloads of 3 books not opened in 7 days. All stay in iCloud Drive."
        )
    }

    /// The status's details say what the device's choice left undone: books kept for want of a proven copy, and books
    /// not downloaded for want of room, in the device's own words.
    func testTheStatusSaysWhatTheChoiceLeftUndone() {
        var status = SyncStatus()
        status.isOn = true
        status.lastSynced = start
        XCTAssertEqual(SyncStatusLine.detailLines(for: status, time: { _ in "9:41 AM" }, isPhone: false), [])

        status.removalsWaiting = 3
        status.booksShortOfRoom = 2
        XCTAssertEqual(SyncStatusLine.detailLines(for: status, time: { _ in "9:41 AM" }, isPhone: false), [
            "Staying on this Mac for now, until iCloud Drive's copies are confirmed: 3 books.",
            "There isn't room on this Mac to download 2 books. The books already here stay.",
        ])
        XCTAssertEqual(
            SyncStatusLine.detailLines(for: status, time: { _ in "9:41 AM" }, isPhone: true).last,
            "There isn't room on this iPhone to download 2 books. The books already here stay."
        )
    }
}
