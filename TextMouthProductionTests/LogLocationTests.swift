import XCTest
@testable import TextMouth

/// Where the diagnostic logs are written (the user's decision of October 3):
/// inside the data directory by default, or in this Mac's Logs folder, as
/// Storage settings choose.
final class LogLocationTests: XCTestCase {

    // MARK: - The Setting

    /// The setting is saved as "dataDirectory" or "machine", and the data
    /// directory is the default.
    func testTheDataDirectoryIsTheDefaultOfTwoChoices() {
        XCTAssertEqual(SettingsPolicy.logLocation.key, "logLocation")
        XCTAssertEqual(SettingsPolicy.logLocation.defaultValue, .dataDirectory)
        XCTAssertEqual(SettingsPolicy.logLocation.allowedRawValues, ["dataDirectory", "machine"])
        XCTAssertEqual(LogLocation.preference.key, SettingsPolicy.logLocation.key)
    }

    /// The preference reads the choice saved, and the default for a missing
    /// value or one it can't use: a choice a later version may add, another
    /// spelling, or a number `defaults write` stored.
    func testThePreferenceReadsTheSavedChoiceOrTheDefault() {
        let store = makeSandboxedPreferences("log-location")
        XCTAssertEqual(LogLocation.preference.read(from: store), .dataDirectory)

        LogLocation.preference.write(.machine, to: store)
        XCTAssertEqual(store.string(forKey: "logLocation"), "machine")
        XCTAssertEqual(LogLocation.preference.read(from: store), .machine)

        for unusable: Any in ["cloud", "", "Machine", 1] {
            store.set(unusable, forKey: "logLocation")
            XCTAssertEqual(LogLocation.preference.read(from: store), .dataDirectory, "\(unusable)")
        }
    }
}
