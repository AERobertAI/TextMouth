import XCTest
@testable import TextMouth

/// The phone's own settings as the Settings screen reads and writes them,
/// through `PhoneDefaults`, the one place they're kept: the two navigation
/// units' rows, which never say a unit they don't offer, and Follow in
/// Braille. Each test has a sandboxed preferences store of its own.
@MainActor
final class PhoneSettingsDefaultsTests: XCTestCase {
    /// The keys are the ones the phone's frame and reader read.
    func testTheKeysAreThePhonesOwn() {
        XCTAssertEqual(PhoneDefaults.textNavigationUnitKey, "phoneTextNavigationUnit")
        XCTAssertEqual(PhoneDefaults.audioNavigationUnitKey, "phoneAudioNavigationUnit")
        XCTAssertEqual(PhoneDefaults.followInBrailleKey, "phoneFollowInBraille")
        XCTAssertEqual(PhoneDefaults.shakeRestartsSleepTimerKey, "phoneShakeRestartsSleepTimer")
        XCTAssertEqual(PhoneDefaults.hidesSkipsFromVoiceOverKey, "phoneHidesSkipsFromVoiceOver")
    }

    /// Nothing stored, the rows say the defaults the reviews gave: Sentence
    /// for a text book, 15 seconds for an audiobook; Follow in Braille is
    /// off, Shake to restart the timer is on (FR55), and Hide skip buttons
    /// from VoiceOver is off (FR54).
    func testNothingStoredSaysTheDefaults() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        XCTAssertEqual(PhoneSettingsModel.textNavigationUnit(in: store), .sentence)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds15)
        XCTAssertFalse(PhoneDefaults.followInBraille(in: store))
        XCTAssertTrue(PhoneDefaults.shakeRestartsSleepTimer(in: store))
        XCTAssertFalse(PhoneDefaults.hidesSkipsFromVoiceOver(in: store))
    }

    /// Hide skip buttons from VoiceOver is kept as a Boolean, and reads back
    /// either way.
    func testHideSkipButtonsIsKeptAsItIsSet() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")

        PhoneDefaults.setHidesSkipsFromVoiceOver(true, in: store)
        XCTAssertTrue(PhoneDefaults.hidesSkipsFromVoiceOver(in: store))
        XCTAssertEqual(store.object(forKey: "phoneHidesSkipsFromVoiceOver") as? Bool, true)

        PhoneDefaults.setHidesSkipsFromVoiceOver(false, in: store)
        XCTAssertFalse(PhoneDefaults.hidesSkipsFromVoiceOver(in: store))
    }

    /// Shake to restart the timer is kept as a Boolean, and reads back either
    /// way: turned off, it stays off, though nothing stored reads as on.
    func testShakeToRestartIsKeptAsItIsSet() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")

        PhoneDefaults.setShakeRestartsSleepTimer(false, in: store)
        XCTAssertFalse(PhoneDefaults.shakeRestartsSleepTimer(in: store))
        XCTAssertEqual(store.object(forKey: "phoneShakeRestartsSleepTimer") as? Bool, false)

        PhoneDefaults.setShakeRestartsSleepTimer(true, in: store)
        XCTAssertTrue(PhoneDefaults.shakeRestartsSleepTimer(in: store))
    }

    /// A choice the rows' sheets make is kept as the unit's raw value, and the
    /// row says it after.
    func testAChoiceIsKeptAndTheRowSaysIt() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")

        PhoneDefaults.setTextNavigationUnit(.heading, in: store)
        PhoneDefaults.setAudioNavigationUnit(.seconds60, in: store)

        XCTAssertEqual(PhoneSettingsModel.textNavigationUnit(in: store), .heading)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds60)
        XCTAssertEqual(store.string(forKey: "phoneTextNavigationUnit"), "Heading")
        XCTAssertEqual(store.string(forKey: "phoneAudioNavigationUnit"), "60 seconds")
    }

    /// A unit an audiobook can't move by, kept from anywhere, has the row say
    /// the audiobook's default, so the row never says a unit its sheet doesn't
    /// offer.
    func testAnAudiobookUnitTheRowDoesntOfferSaysTheDefault() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        store.set("Sentence", forKey: PhoneDefaults.audioNavigationUnitKey)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds15)
        store.set("Paragraph", forKey: PhoneDefaults.audioNavigationUnitKey)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds15)
    }

    /// A value that names no unit has the row say the default too.
    func testAValueNamingNoUnitSaysTheDefault() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        store.set("Chapter and verse", forKey: PhoneDefaults.textNavigationUnitKey)
        store.set(12, forKey: PhoneDefaults.audioNavigationUnitKey)
        XCTAssertEqual(PhoneSettingsModel.textNavigationUnit(in: store), .sentence)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds15)
    }

    /// Every unit each row offers is kept and said back as itself.
    func testEveryOfferedUnitIsSaidBack() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        for unit in PhoneSettingsModel.textNavigationUnits {
            PhoneDefaults.setTextNavigationUnit(unit, in: store)
            XCTAssertEqual(PhoneSettingsModel.textNavigationUnit(in: store), unit)
        }
        for unit in PhoneSettingsModel.audioNavigationUnits {
            PhoneDefaults.setAudioNavigationUnit(unit, in: store)
            XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), unit)
        }
    }

    /// Follow in Braille is kept as a Boolean, and reads back either way.
    func testFollowInBrailleIsKeptAsItIsSet() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")

        PhoneDefaults.setFollowInBraille(true, in: store)
        XCTAssertTrue(PhoneDefaults.followInBraille(in: store))
        XCTAssertEqual(store.object(forKey: "phoneFollowInBraille") as? Bool, true)

        PhoneDefaults.setFollowInBraille(false, in: store)
        XCTAssertFalse(PhoneDefaults.followInBraille(in: store))
    }

    // MARK: - The Braille Table in config.json

    /// A table config.json refuses is written empty, the file's "keep the
    /// current choice", so that it is not repaired and logged at every launch;
    /// a Mac table's value is kept as it is.
    func testConfigKeepsOnlyABrailleTableItAccepts() {
        XCTAssertEqual(PhoneDefaults.configBrailleTable(for: "no-such-table.ctb"), "")
        XCTAssertEqual(PhoneDefaults.configBrailleTable(for: ""), "")
        XCTAssertEqual(PhoneDefaults.configBrailleTable(for: "mac:fr-bfu-g2.ctb"), "mac:fr-bfu-g2.ctb")
        // Whatever it writes, reading it back changes nothing.
        for stored in ["no-such-table.ctb", "mac:fr-bfu-g2.ctb", BrailleTableCatalog.defaultTableID] {
            let written = PhoneDefaults.configBrailleTable(for: stored)
            XCTAssertEqual(BrailleTableCatalog.storableValue(written) ?? "", written, stored)
        }
    }

    /// A braille table config.json names that this platform lacks is written back as the file has it, until the table is
    /// changed on this device: the launch's save must not hand the other platform this one's choice. This runs in the iPhone's
    /// unit bundle and the Mac's alike, so the iPhone's own path (`brailleTableForConfig`, which writes an empty value for a
    /// table its bundle lacks) is tested where it runs.
    func testAFileTableThisPlatformLacksIsWrittenBackUntilTheTableIsChanged() throws {
        let theirs = "table-only-the-other-platform-has.ctb"
        let folder = try makeSandboxDirectory("PhoneBrailleHold")
        let service = ConfigService(fileURL: folder.appendingPathComponent("config.json"))
        addTeardownBlock { service._dropScheduledSaveForTesting() }
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(), initializeServices: false,
            userDefaults: makeSandboxedPreferences("PhoneBrailleHold"), configService: service
        )
        let own = BrailleTableCatalog.defaultTableID
        var file = ConfigService.AppConfig()
        file.brailleTable = theirs

        // Applying the file takes nothing of it, and what the launch's save writes is the file's value.
        settings.applyConfigChanges(file)
        XCTAssertEqual(settings.brailleTable, own, "a table this platform lacks was taken")
        var written = ConfigService.AppConfig()
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.brailleTable, theirs, "the save handed the other platform this one's table")
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.brailleTable, theirs)

        // A change on this device replaces it, and stays replaced.
        settings.brailleTable = "en-us-g1.ctb"
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.brailleTable, "en-us-g1.ctb")
        settings.writePreferences(into: &written)
        XCTAssertEqual(written.brailleTable, "en-us-g1.ctb")
    }
}
