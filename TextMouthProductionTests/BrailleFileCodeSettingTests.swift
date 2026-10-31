import Combine
import XCTest
@testable import TextMouth

/// The braille file characters setting (braillecodes,
/// BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.3) in the settings model
/// and in config.json, where it is `brailleFileCode`: the model takes only a
/// code of the catalog; a change is announced and written to config.json;
/// and config.json's value is adopted when it names a code, while an empty
/// id, or one this TextMouth lacks, leaves the setting alone. Each test's
/// settings live in a sandboxed preferences store and a config.json of the
/// test's own; nothing touches the real ones.
@MainActor
final class BrailleFileCodeSettingTests: XCTestCase {

    // MARK: - The Settings Model

    /// The model reads North American Braille ASCII while nothing is
    /// stored, without storing it, and takes each of the import's choices
    /// (the seven-bit codes) by its id, storing that. Unicode braille
    /// patterns are recognized by a file's bytes, never chosen for an
    /// import (review finding 4): the model refuses them and keeps its code.
    func testTheModelTakesTheImportsChoicesAndRefusesUnicode() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        XCTAssertEqual(settings.brailleFileCode, "ascii-na")
        XCTAssertNil(defaults.object(forKey: "brailleFileCode"), "reading the default stored it")
        for id in ["ascii-eurobraille", "ascii-na"] {
            settings.brailleFileCode = id
            XCTAssertEqual(settings.brailleFileCode, id)
            XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), id)
        }
        settings.brailleFileCode = "unicode"
        XCTAssertEqual(settings.brailleFileCode, "ascii-na")
        XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), "ascii-na")
    }

    /// The model refuses an id that names no code of the catalog (a later
    /// TextMouth's, one in capitals, a code's name, or none at all), and
    /// takes the code already chosen as no change: the code stays, in the
    /// model and in the store, and nothing is announced.
    func testTheModelRefusesAnIDThatNamesNoCode() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        settings.brailleFileCode = "ascii-eurobraille"
        var announcements = 0
        let counter = settings.objectWillChange.sink { announcements += 1 }
        defer { counter.cancel() }

        for refused in ["ascii-future", "ASCII-NA", "North American Braille ASCII", "", "ascii-eurobraille"] {
            settings.brailleFileCode = refused
            XCTAssertEqual(settings.brailleFileCode, "ascii-eurobraille", "the model took \"\(refused)\"")
            XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), "ascii-eurobraille", "the store took \"\(refused)\"")
        }
        XCTAssertEqual(announcements, 0, "a refused or unchanged code was announced")
    }

    // MARK: - config.json

    /// A change of the setting, made in the model or in the store by
    /// anything else (as `defaults write` makes one), is announced, so the
    /// Braille tab's pop-up follows, and written to config.json by the
    /// code's id.
    func testAChangeIsAnnouncedAndWrittenToConfigJSON() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: defaults, configService: service
        )

        // In the model.
        settings.brailleFileCode = "ascii-eurobraille"
        XCTAssertTrue(
            waitUntil { service.config.brailleFileCode == "ascii-eurobraille" },
            "the config holds \(service.config.brailleFileCode)"
        )
        service.flushScheduledSave()
        XCTAssertEqual(try savedString("brailleFileCode", in: url), "ascii-eurobraille")

        // In the store, by anything else.
        var announcements = 0
        let counter = settings.objectWillChange.sink { announcements += 1 }
        defer { counter.cancel() }
        // Back to North American Braille ASCII, the other choice, so the
        // store really changes.
        BraillePreferences.fileCode.write("ascii-na", to: defaults)
        XCTAssertTrue(
            waitUntil { announcements > 0 && service.config.brailleFileCode == "ascii-na" },
            "announced \(announcements) times; the config holds \(service.config.brailleFileCode)"
        )
        XCTAssertEqual(settings.brailleFileCode, "ascii-na")
        service.flushScheduledSave()
        XCTAssertEqual(try savedString("brailleFileCode", in: url), "ascii-na")
    }

    /// config.json's `brailleFileCode` is adopted into the store when it
    /// names one of the import's choices: each seven-bit code in turn, read
    /// from the file's text as a launch or an edit reads it.
    func testACodeConfigJSONNamesIsAdopted() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        for id in ["ascii-eurobraille", "ascii-na"] {
            settings.applyConfigChanges(try decodedConfig(["brailleFileCode": id]))
            XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), id)
            XCTAssertEqual(settings.brailleFileCode, id)
        }
    }

    /// An empty id, one this TextMouth lacks, Unicode braille patterns'
    /// (recognized by a file's bytes, never the import's choice, review
    /// finding 4), or no field at all, as in a file an older TextMouth
    /// wrote, leaves the store's code alone. Decoding repairs an id that
    /// names no choice to empty; the model refuses one too, should a
    /// configuration hold it all the same.
    func testAnEmptyOrUnknownIDLeavesTheStoresCodeAlone() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        BraillePreferences.fileCode.write("ascii-eurobraille", to: defaults)

        for id in ["", "ascii-future", "ASCII-NA", "Unicode braille patterns", "unicode"] {
            let decoded = try decodedConfig(["brailleFileCode": id])
            XCTAssertEqual(decoded.brailleFileCode, "", "decoding kept \"\(id)\"")
            settings.applyConfigChanges(decoded)
            var unrepaired = decoded
            unrepaired.brailleFileCode = id
            settings.applyConfigChanges(unrepaired)
            XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), "ascii-eurobraille", "\"\(id)\" changed the code")
        }
        settings.applyConfigChanges(try decodedConfig([:]))
        XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), "ascii-eurobraille", "a file without the field changed the code")
    }

    /// An id this TextMouth lacks is logged once as config.json's repair of
    /// `brailleFileCode`, naming the id the file held.
    func testAnUnknownIDIsLoggedAsARepair() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let unknown = "ascii-\(UUID().uuidString.lowercased())"

        XCTAssertEqual(try decodedConfig(["brailleFileCode": unknown]).brailleFileCode, "")

        let lines = debugLogLines(containing: unknown)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("config.json brailleFileCode") ?? false, "\(lines)")
    }

    // MARK: - Helpers

    /// A settings model on `defaults`, with a config.json of the test's own,
    /// that starts no services and posts only to a notification center of
    /// its own.
    private func makeSettings(defaults: UserDefaults) throws -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: ConfigService(fileURL: try makeConfigFileURL())
        )
    }

    /// config.json holding `fields` and the data directory in use, decoded
    /// as a launch or an edit decodes it. The data directory is the one in
    /// use, so applying the file asks for no move of the library.
    private func decodedConfig(_ fields: [String: Any]) throws -> ConfigService.AppConfig {
        var object = fields
        object["dataDirectoryPath"] = ConfigService.AppConfig.currentDataDirectoryPath
        return try ConfigService.decode(JSONSerialization.data(withJSONObject: object))
    }

    /// The text config.json at `url` holds for `field`, or nil.
    private func savedString(_ field: String, in url: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?[field] as? String
    }
}
