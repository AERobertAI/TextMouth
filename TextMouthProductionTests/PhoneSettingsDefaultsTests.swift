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
    }

    /// Nothing stored, the rows say the defaults the reviews gave: Sentence
    /// for a text book, 15 seconds for an audiobook; and Follow in Braille is
    /// off.
    func testNothingStoredSaysTheDefaults() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        XCTAssertEqual(PhoneSettingsModel.textNavigationUnit(in: store), .sentence)
        XCTAssertEqual(PhoneSettingsModel.audioNavigationUnit(in: store), .seconds15)
        XCTAssertFalse(PhoneDefaults.followInBraille(in: store))
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
}
