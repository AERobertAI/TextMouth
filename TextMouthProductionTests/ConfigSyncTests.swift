import XCTest
@testable import TextMouth

/// Regression coverage for config/AppStorage mapping and watcher replacement.
@MainActor
final class ConfigSyncTests: XCTestCase {
    func testSettingsPushAllPreviouslyOmittedFieldsToConfig() {
        let defaults = UserDefaults.standard
        let keys = [
            "shiftSkipForwardUnit", "shiftSkipBackwardUnit",
            "endOfBookBehavior", "punctuationPauseLevel",
        ]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false
        )
        let service = ConfigService.shared
        let previous = service.config
        defer {
            service.config = previous
            service.saveToDisk()
            for key in keys {
                if let value = previousDefaults[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        viewModel.shiftSkipForwardUnitRaw = SkipUnit.seconds60.rawValue
        viewModel.shiftSkipBackwardUnitRaw = SkipUnit.sentence.rawValue
        viewModel.endOfBookBehaviorRaw = EndOfBookBehavior.loop.rawValue
        viewModel.punctuationPauseLevel = 2
        viewModel.syncToConfig()

        XCTAssertEqual(service.config.shiftSkipForwardUnit, SkipUnit.seconds60.rawValue)
        XCTAssertEqual(service.config.shiftSkipBackwardUnit, SkipUnit.sentence.rawValue)
        XCTAssertEqual(service.config.endOfBookBehavior, EndOfBookBehavior.loop.rawValue)
        XCTAssertEqual(service.config.punctuationPauseLevel, 2)
    }

    func testExternalConfigAppliesAllPreviouslyOmittedFields() {
        let defaults = UserDefaults.standard
        let keys = [
            "shiftSkipForwardUnit", "shiftSkipBackwardUnit",
            "endOfBookBehavior", "punctuationPauseLevel",
        ]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previousDefaults[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false
        )
        var config = ConfigService.AppConfig()
        config.shiftSkipForwardUnit = SkipUnit.heading.rawValue
        config.shiftSkipBackwardUnit = SkipUnit.paragraph.rawValue
        config.endOfBookBehavior = EndOfBookBehavior.continueNext.rawValue
        config.punctuationPauseLevel = 3

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(viewModel.shiftSkipForwardUnit, .heading)
        XCTAssertEqual(viewModel.shiftSkipBackwardUnit, .paragraph)
        XCTAssertEqual(viewModel.endOfBookBehavior, .continueNext)
        XCTAssertEqual(viewModel.punctuationPauseLevel, 3)
    }

    func testAtomicReplacementRearmsWatcherDuringInternalSave() {
        let actions = ConfigService.watcherActions(for: .rename, isSaving: true)

        XCTAssertFalse(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    func testExternalAtomicReplacementReloadsAndRearmsWatcher() {
        let actions = ConfigService.watcherActions(for: [.write, .rename], isSaving: false)

        XCTAssertTrue(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    func testExternalDataPathRequestsMigrationWithoutImmediatelySwitchingRoot() {
        let notificationCenter = NotificationCenter()
        let viewModel = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: false
        )
        var config = ConfigService.AppConfig()
        config.dataDirectoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth-External-Request-\(UUID().uuidString)")
            .path
        let originalRoot = TextMouthPaths.root
        let expectation = XCTNSNotificationExpectation(
            name: .dataDirectoryChangeRequested,
            object: nil,
            notificationCenter: notificationCenter
        )
        expectation.handler = { note in
            note.userInfo?["path"] as? String == config.dataDirectoryPath
        }

        viewModel.applyConfigChanges(config)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(TextMouthPaths.root, originalRoot)
    }
}
