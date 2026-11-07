import XCTest
@testable import TextMouth

/// The phone's own settings: their keys, their defaults, and that a stored
/// value can only ever read as a unit its row offers. Each test has a
/// sandboxed preferences store of its own.
final class PhoneSettingsDefaultsTests: XCTestCase {
    /// The keys are the ones the phone's frame reads them by.
    func testTheKeysAreThePhonesOwn() {
        XCTAssertEqual(PhoneSettingsDefaults.textNavigationUnit.key, "phoneTextNavigationUnit")
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.key, "phoneAudioNavigationUnit")
        XCTAssertEqual(PhoneSettingsDefaults.followInBraille.key, "phoneFollowInBraille")
    }

    /// Nothing stored reads as the defaults the reviews gave: Sentence for a
    /// text book, 15 seconds for an audiobook, and Follow in Braille off.
    func testNothingStoredReadsAsTheDefaults() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        XCTAssertEqual(PhoneSettingsDefaults.textNavigationUnit.read(from: store), .sentence)
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), .seconds15)
        XCTAssertFalse(PhoneSettingsDefaults.followInBraille.read(from: store))
    }

    /// What is written reads back, kept as the unit's raw value.
    func testAChoiceReadsBackAsItWasWritten() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")

        PhoneSettingsDefaults.textNavigationUnit.write(.heading, to: store)
        PhoneSettingsDefaults.audioNavigationUnit.write(.seconds60, to: store)
        PhoneSettingsDefaults.followInBraille.write(true, to: store)

        XCTAssertEqual(PhoneSettingsDefaults.textNavigationUnit.read(from: store), .heading)
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), .seconds60)
        XCTAssertTrue(PhoneSettingsDefaults.followInBraille.read(from: store))
        XCTAssertEqual(store.string(forKey: "phoneTextNavigationUnit"), "Heading")
        XCTAssertEqual(store.string(forKey: "phoneAudioNavigationUnit"), "60 seconds")
    }

    /// A unit an audiobook can't move by, stored from anywhere, reads as its
    /// default, so the row never says a unit it doesn't offer.
    func testAnAudiobookUnitTheRowDoesntOfferReadsAsTheDefault() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        store.set("Sentence", forKey: "phoneAudioNavigationUnit")
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), .seconds15)
        store.set("Paragraph", forKey: "phoneAudioNavigationUnit")
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), .seconds15)
    }

    /// A value that names no unit reads as the default too.
    func testAValueNamingNoUnitReadsAsTheDefault() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        store.set("Chapter and verse", forKey: "phoneTextNavigationUnit")
        store.set(12, forKey: "phoneAudioNavigationUnit")
        XCTAssertEqual(PhoneSettingsDefaults.textNavigationUnit.read(from: store), .sentence)
        XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), .seconds15)
    }

    /// Every unit each row offers is kept and read back as itself.
    func testEveryOfferedUnitReadsBack() {
        let store = makeSandboxedPreferences("PhoneSettingsDefaults")
        for unit in PhoneSettingsModel.textNavigationUnits {
            PhoneSettingsDefaults.textNavigationUnit.write(unit, to: store)
            XCTAssertEqual(PhoneSettingsDefaults.textNavigationUnit.read(from: store), unit)
        }
        for unit in PhoneSettingsModel.audioNavigationUnits {
            PhoneSettingsDefaults.audioNavigationUnit.write(unit, to: store)
            XCTAssertEqual(PhoneSettingsDefaults.audioNavigationUnit.read(from: store), unit)
        }
    }
}
