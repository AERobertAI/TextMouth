import SwiftUI

/// The words of Storage settings' Logs group, each defined once for the
/// screen, VoiceOver, a braille display, and the tests.
enum LogsSettingsWording {
    /// The group's heading.
    static var title: String {
        // Translators: Heading of the Logs group in the Storage settings, which holds the choice of where TextMouth writes its diagnostic logs.
        InterfaceText.line("logsSettings.title", "Logs")
    }

    /// The picker's label, on screen and for VoiceOver alike.
    static var pickerLabel: String {
        // Translators: Label of the pop-up in the Storage settings that chooses where TextMouth writes its diagnostic logs.
        InterfaceText.line("logsSettings.pickerLabel", "Log location")
    }

    /// The first choice's name, without the folder: the logs go inside the
    /// data directory.
    private static var dataDirectoryChoice: String {
        // Translators: A choice of the Log location pop-up in the Storage settings: the diagnostic logs are written in the Logs folder of the data directory, the folder that holds the library.
        InterfaceText.line("logsSettings.dataDirectoryChoice", "Inside the data directory")
    }

    /// The second choice's name, without the folder: the logs go in this
    /// Mac's own Logs folder.
    private static var machineChoice: String {
        // Translators: A choice of the Log location pop-up in the Storage settings, and its name inside the pop-up's hint: the diagnostic logs are written in a folder on this Mac that never syncs. The folder's path follows in parentheses where the choice is listed.
        InterfaceText.line("logsSettings.machineChoice", "In this Mac's Logs folder")
    }

    /// What each choice is called in the picker; VoiceOver reads the one in
    /// force as the picker's value.
    static func optionTitle(_ location: LogLocation) -> String {
        switch location {
        case .dataDirectory:
            return dataDirectoryChoice
        case .machine:
            // Translators: The second choice of the Log location pop-up in the Storage settings. %1$@ is the choice's name, and %2$@ is the folder's name on this Mac, a path that stays as written, such as ~/Library/Logs/TextMouth.
            return InterfaceText.line("common.valueInParentheses", "\(machineChoice) (\(MachineLocalPaths.logsName))")
        }
    }

    /// What the picker chooses between, as VoiceOver's hint and the
    /// pointer's help tag say it: both choices, and that a change applies to
    /// the next line and moves no file.
    static var pickerHint: String {
        // Translators: VoiceOver hint and tooltip of the Log location pop-up in the Storage settings. %1$@ and %2$@ are the names of its two choices, as the pop-up lists them, and %3$@ is the folder's path on this Mac, which stays as written.
        InterfaceText.line("logsSettings.pickerHint", "Where TextMouth writes its diagnostic logs. \(dataDirectoryChoice) keeps them with your books, so they move and sync with the library. \(machineChoice) keeps them in \(MachineLocalPaths.logsName), which never syncs. A change applies from the next line; existing logs stay.")
    }

    /// Where the logs are written now, as the line under the picker says it:
    /// the folder in full, and, while lines can't go where the choice asks,
    /// why and until when.
    static func status(of destination: LogDestination) -> String {
        let folder = destination.folder.path
        switch destination.reason {
        case .dataDirectory, .thisMac:
            // Translators: The line under the Log location pop-up in the Storage settings. %@ is the folder's full path, which stays as written.
            return InterfaceText.line("logsSettings.status.dataDirectory", "Logs are written to \(folder).")
        case .fallback(.libraryUnavailable):
            // Translators: The line under the Log location pop-up in the Storage settings while the library cannot be reached. %@ is the folder's full path, which stays as written.
            return InterfaceText.line("logsSettings.status.fallback.available", "The library isn't available, so logs go to \(folder) until it is.")
        case .fallback(.dataDirectoryMissing):
            // Translators: The line under the Log location pop-up in the Storage settings while the data directory is missing. %@ is the folder's full path, which stays as written.
            return InterfaceText.line("logsSettings.status.fallback.missing", "The data directory is missing, so logs go to \(folder) until it is back.")
        case .fallback(.logsFolderMissing):
            // Translators: The line under the Log location pop-up in the Storage settings while the data directory has no Logs folder. %@ is the folder's full path, which stays as written.
            return InterfaceText.line("logsSettings.status.fallback.noOne", "The data directory has no Logs folder, so logs go to \(folder) until it has one.")
        case .fallback(.logsFolderUnusable(let reason)):
            // Translators: The line under the Log location pop-up in the Storage settings while the data directory's Logs folder cannot be written. %1$@ is the reason the system gives, which may be in English, and %2$@ is the folder's full path, which stays as written.
            return InterfaceText.line("logsSettings.status.fallback.written", "The data directory's Logs folder can't be written (\(reason)), so logs go to \(folder) until it can.")
        }
    }

    /// The button that opens the folder the logs are written to now.
    static var showTitle: String {
        // Translators: Title of the button in the Storage settings that shows the folder the diagnostic logs are written to, in Finder.
        InterfaceText.line("logsSettings.showTitle", "Show Logs in Finder")
    }

    /// What that button does, naming the folder it opens.
    static func showHint(folder: URL) -> String {
        // Translators: VoiceOver hint and tooltip of the Show Logs in Finder button. %@ is the folder's full path, which stays as written.
        InterfaceText.line("logsSettings.showHint", "Opens \(folder.path), the folder the logs are written to now, in Finder.")
    }

    /// What the line under the button says, and VoiceOver hears, when
    /// Finder could not open the folder.
    static func showFailure(folder: URL) -> String {
        // Translators: Shown under the Show Logs in Finder button when Finder could not open the folder. %@ is the folder's full path, which stays as written.
        InterfaceText.line("logsSettings.showFailure", "TextMouth couldn't open \(folder.path) in Finder.")
    }
}

/// Storage settings' Logs group (the user's decision of October 3): where
/// TextMouth writes its diagnostic logs, inside the data directory or in
/// this Mac's Logs folder; where they are written now; and a button that
/// shows them in Finder.
///
/// Every control carries an explicit label, value, and hint, so each makes
/// sense to VoiceOver and on a braille display without its place on screen:
/// the picker's label names it, its value is the choice in force, and its
/// hint explains both choices and that a change moves no file. The line
/// under it names the folder in use in full, as selectable text, and says
/// why while the library isn't available. The group is a plain section of
/// the Storage form, whose heading VoiceOver reads first.
struct LogsSettingsSection: View {
    /// The choice, which the settings model keeps in the preferences store,
    /// where the log writer reads it, and in config.json.
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The library model. Its changes, such as finding the data directory
    /// unavailable or moving it, change where the logs go, so they redraw
    /// the line naming the folder.
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    /// What the last Show Logs in Finder said went wrong, if it failed.
    @State private var showFailure: String?

    var body: some View {
        Section {
            Picker(LogsSettingsWording.pickerLabel, selection: $settingsViewModel.logLocation) {
                ForEach(LogLocation.allCases, id: \.self) { location in
                    Text(LogsSettingsWording.optionTitle(location)).tag(location)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(LogsSettingsWording.pickerLabel)
            .accessibilityHint(LogsSettingsWording.pickerHint)
            .help(LogsSettingsWording.pickerHint)

            Text(LogsSettingsWording.status(of: destination))
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button(LogsSettingsWording.showTitle) {
                showFailure = LogsInFinder.show(for: settingsViewModel.logLocation)
            }
            .accessibilityLabel(LogsSettingsWording.showTitle)
            .accessibilityHint(LogsSettingsWording.showHint(folder: destination.folder))
            .help(LogsSettingsWording.showHint(folder: destination.folder))

            if let showFailure {
                // The words say it failed, so the color is never the only sign.
                Text(showFailure)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(LogsSettingsWording.title)
        }
    }

    /// Where the logs are written now under the choice shown.
    private var destination: LogDestination {
        TextMouthPaths.logDestination(for: settingsViewModel.logLocation)
    }
}
