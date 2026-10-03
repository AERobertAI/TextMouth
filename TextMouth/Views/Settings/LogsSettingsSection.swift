import SwiftUI

/// The words of Storage settings' Logs group, each defined once for the
/// screen, VoiceOver, a braille display, and the tests.
enum LogsSettingsWording {
    /// The group's heading.
    static let title = "Logs"

    /// The picker's label, on screen and for VoiceOver alike.
    static let pickerLabel = "Log location"

    /// What each choice is called in the picker; VoiceOver reads the one in
    /// force as the picker's value.
    static func optionTitle(_ location: LogLocation) -> String {
        switch location {
        case .dataDirectory:
            return "Inside the data directory"
        case .machine:
            return "In this Mac's Logs folder (\(MachineLocalPaths.logsName))"
        }
    }

    /// What the picker chooses between, as VoiceOver's hint and the
    /// pointer's help tag say it: both choices, and that a change applies to
    /// the next line and moves no file.
    static let pickerHint = "Chooses where TextMouth writes its diagnostic logs. "
        + "Inside the data directory keeps them in its Logs folder, beside your books, "
        + "where they move with the library and sync with it when it is in the cloud. "
        + "In this Mac's Logs folder keeps them in \(MachineLocalPaths.logsName), which never syncs. "
        + "A change applies from the next line written; logs already written are not moved."

    /// Where the logs are written now, as the line under the picker says it:
    /// the folder in full, and, while lines can't go where the choice asks,
    /// why and until when.
    static func status(of destination: LogDestination) -> String {
        let folder = destination.folder.path
        switch destination.reason {
        case .dataDirectory, .thisMac:
            return "Logs are written to \(folder)."
        case .fallback(.libraryUnavailable):
            return "The library isn't available, so logs are written to \(folder) until it is."
        case .fallback(.dataDirectoryMissing):
            return "The data directory is missing, so logs are written to \(folder) until it is back."
        case .fallback(.logsFolderMissing):
            return "The data directory has no Logs folder, so logs are written to \(folder) until it has one again."
        case .fallback(.logsFolderUnusable(let reason)):
            return "The data directory's Logs folder can't be written (\(reason)), so logs are written to \(folder) until it can."
        }
    }

    /// The button that opens the folder the logs are written to now.
    static let showTitle = "Show Logs in Finder"

    /// What that button does, naming the folder it opens.
    static func showHint(folder: URL) -> String {
        "Opens \(folder.path), the folder the logs are written to now, in Finder."
    }

    /// What the line under the button says, and VoiceOver hears, when
    /// Finder could not open the folder.
    static func showFailure(folder: URL) -> String {
        "TextMouth couldn't open \(folder.path) in Finder."
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
                showFailure = Self.showLogs(for: settingsViewModel.logLocation)
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

    /// Show Logs in Finder: opens, through `open`, the folder the logs go
    /// to now under `location`, this Mac's made first when it is missing,
    /// and returns what the line under the button says when that failed,
    /// nil when it worked. VoiceOver hears a failure at once; after a
    /// success, Finder's window takes the focus.
    @MainActor
    static func showLogs(
        for location: LogLocation,
        opening open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> String? {
        let folder = TextMouthPaths.preparedLogsFolder(for: location)
        guard !open(folder) else { return nil }
        let failure = LogsSettingsWording.showFailure(folder: folder)
        VoiceOverAnnouncer.announce(failure)
        return failure
    }
}
