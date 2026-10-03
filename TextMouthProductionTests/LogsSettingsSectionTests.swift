import SwiftUI
import XCTest
@testable import TextMouth

/// Storage settings' Logs group (the user's decision of October 3), as
/// VoiceOver and a braille display meet it, and its Show Logs in Finder.
/// The group is hosted with a settings model on a store of the test's own,
/// so choosing in it never changes where the app's logs go.
@MainActor
final class LogsSettingsSectionTests: XCTestCase {

    // MARK: - Wording

    /// The picker offers the two choices by the names the user asked for,
    /// and its hint explains both and says a change moves no file.
    func testTheChoicesAreNamedAndExplained() {
        XCTAssertEqual(LogLocation.allCases.map(LogsSettingsWording.optionTitle), [
            "Inside the data directory",
            "In this Mac's Logs folder (~/Library/Logs/TextMouth)",
        ])
        for words in [
            "Inside the data directory keeps them in its Logs folder", "sync with it when it is in the cloud",
            "In this Mac's Logs folder keeps them in ~/Library/Logs/TextMouth, which never syncs",
            "A change applies from the next line written", "logs already written are not moved",
        ] {
            XCTAssertTrue(LogsSettingsWording.pickerHint.contains(words), words)
        }
    }

    /// Show Logs in Finder says what it does by naming the folder it opens,
    /// and, when Finder can't open it, says so, naming the folder again.
    func testShowLogsInFindersWordsNameTheFolder() {
        let folder = URL(fileURLWithPath: "/Volumes/Backup/TextMouth/Logs", isDirectory: true)

        XCTAssertEqual(LogsSettingsWording.showTitle, "Show Logs in Finder")
        XCTAssertEqual(
            LogsSettingsWording.showHint(folder: folder),
            "Opens /Volumes/Backup/TextMouth/Logs, the folder the logs are written to now, in Finder."
        )
        XCTAssertEqual(
            LogsSettingsWording.showFailure(folder: folder),
            "TextMouth couldn't open /Volumes/Backup/TextMouth/Logs in Finder."
        )
    }

    /// The line under the picker names the folder in use in full, and,
    /// while lines can't go where the choice asks, why and until when.
    func testTheStatusNamesTheFolderInUseAndWhy() {
        let logs = URL(fileURLWithPath: "/Volumes/Backup/TextMouth/Logs", isDirectory: true)
        let thisMac = URL(fileURLWithPath: "/Users/reader/Library/Logs/TextMouth", isDirectory: true)
        let status = { (folder: URL, reason: LogDestination.Reason) in
            LogsSettingsWording.status(of: LogDestination(folder: folder, reason: reason))
        }

        XCTAssertEqual(status(logs, .dataDirectory), "Logs are written to /Volumes/Backup/TextMouth/Logs.")
        XCTAssertEqual(status(thisMac, .thisMac), "Logs are written to /Users/reader/Library/Logs/TextMouth.")
        XCTAssertEqual(
            status(thisMac, .fallback(.libraryUnavailable)),
            "The library isn't available, so logs are written to /Users/reader/Library/Logs/TextMouth until it is."
        )
        XCTAssertEqual(
            status(thisMac, .fallback(.dataDirectoryMissing)),
            "The data directory is missing, so logs are written to /Users/reader/Library/Logs/TextMouth until it is back."
        )
        XCTAssertEqual(
            status(thisMac, .fallback(.logsFolderMissing)),
            "The data directory has no Logs folder, so logs are written to /Users/reader/Library/Logs/TextMouth "
                + "until it has one again."
        )
        XCTAssertEqual(
            status(thisMac, .fallback(.logsFolderUnusable("it is only in the cloud"))),
            "The data directory's Logs folder can't be written (it is only in the cloud), so logs are written to "
                + "/Users/reader/Library/Logs/TextMouth until it can."
        )
    }

    // MARK: - The Hosted Group

    /// VoiceOver finds the picker by its label, hears the choice in force
    /// as its value and both choices in its hint, and hears a choice made
    /// elsewhere, as an edit of config.json makes one, as the new value.
    func testThePickerSpeaksItsLabelValueAndHint() throws {
        let settings = makeSettings()

        try withHostedView(makeGroup(settings), size: NSSize(width: 600, height: 400), until: { !self.logPickers(in: $0).isEmpty }) { hosting in
            let picker = try XCTUnwrap(logPickers(in: hosting).first, "\(accessibleControls(in: hosting).map(\.label))")
            XCTAssertEqual(picker.hint, LogsSettingsWording.pickerHint)
            XCTAssertEqual(picker.element.accessibilityValue() as? String, LogsSettingsWording.optionTitle(.dataDirectory))
            let popUp = try XCTUnwrap(descendants(of: hosting, as: NSPopUpButton.self).first)
            XCTAssertEqual(popUp.itemTitles, LogLocation.allCases.map(LogsSettingsWording.optionTitle))

            settings.logLocation = .machine

            // SwiftUI redraws on a later turn of the run loop, and may draw a
            // new control, so each look finds it again.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return self.logPickers(in: hosting).first?.element.accessibilityValue() as? String
                    == LogsSettingsWording.optionTitle(.machine)
            })
        }
    }

    /// Storage settings show the Logs group: VoiceOver finds its picker by
    /// its label among the pane's controls, with its hint.
    func testStorageSettingsShowTheLogsGroup() throws {
        let view = StorageSettingsView()
            .environmentObject(LibraryViewModel(initializeServices: false))
            .environmentObject(makeSettings())

        try withHostedView(view, size: NSSize(width: 600, height: 1600), until: { !self.logPickers(in: $0).isEmpty }) { hosting in
            let picker = try XCTUnwrap(logPickers(in: hosting).first, "\(accessibleControls(in: hosting).map(\.label))")
            XCTAssertEqual(picker.hint, LogsSettingsWording.pickerHint)
        }
    }

    /// Show Logs in Finder is among the group's labelled buttons, with a
    /// hint naming the folder it opens. SwiftUI exposes its buttons to
    /// accessibility only for a connected assistive app, as VoiceOver is, so
    /// without one this is skipped and the words are checked on their own
    /// (`testShowLogsInFindersWordsNameTheFolder`).
    func testShowLogsInFinderIsLabelledWithTheFolderItOpens() throws {
        try TextMouthPaths.ensureDirectoryStructure()

        try withHostedControls(makeGroup(makeSettings())) { controls in
            let buttons = controls.filter { $0.role == .button }
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            let show = try XCTUnwrap(buttons.first { $0.label == LogsSettingsWording.showTitle }, "\(buttons.map(\.label))")
            XCTAssertEqual(
                show.hint,
                LogsSettingsWording.showHint(folder: TextMouthPaths.logDestination(for: .dataDirectory).folder)
            )
        }
    }

    // MARK: - Show Logs in Finder

    /// Show Logs in Finder opens the folder the logs go to now under the
    /// choice: the data directory's Logs folder, or this Mac's, made first
    /// when it is missing.
    func testShowLogsOpensTheFolderInUse() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        var opened: [String] = []

        XCTAssertNil(LogsSettingsSection.showLogs(for: .dataDirectory) { opened.append($0.standardizedFileURL.path); return true })
        XCTAssertNil(LogsSettingsSection.showLogs(for: .machine) { opened.append($0.standardizedFileURL.path); return true })

        XCTAssertEqual(opened, [
            TextMouthPaths.root.appendingPathComponent("Logs", isDirectory: true).standardizedFileURL.path,
            MachineLocalPaths.logs.standardizedFileURL.path,
        ])
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: MachineLocalPaths.logs.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
    }

    /// When Finder can't open the folder, the line under the button says
    /// so, and VoiceOver hears it at once.
    func testAFolderFinderCannotOpenIsReportedAndAnnounced() {
        var failure: String?

        let recorder = recordingAnnouncements {
            failure = LogsSettingsSection.showLogs(for: .machine) { _ in false }
        }

        let expected = LogsSettingsWording.showFailure(folder: MachineLocalPaths.logs)
        XCTAssertEqual(failure, expected)
        XCTAssertEqual(recorder.announcements, [VoiceOverAnnouncement(message: expected, priority: .high)])
    }

    // MARK: - Fixtures

    /// A settings model on a store of the test's own, starting no services.
    private func makeSettings() -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("LogsSettings")
        )
    }

    /// The Logs group in a form, as Storage settings show it, with
    /// `settings` and an inert library model.
    private func makeGroup(_ settings: SettingsViewModel) -> some View {
        Form {
            LogsSettingsSection()
        }
        .environmentObject(settings)
        .environmentObject(LibraryViewModel(initializeServices: false))
    }

    /// The log location pickers VoiceOver finds in `view`.
    private func logPickers(in view: NSView) -> [AccessibleControl] {
        accessibleControls(in: view).filter { $0.role == .popUpButton && $0.label == LogsSettingsWording.pickerLabel }
    }
}
