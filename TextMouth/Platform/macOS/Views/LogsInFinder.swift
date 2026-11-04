import AppKit

/// Show Logs in Finder, for each place that offers it: Storage settings'
/// Logs group and the reader's speech refusal report.
enum LogsInFinder {
    /// Show Logs in Finder: opens, through `open`, the folder the logs go
    /// to now under `location`, this Mac's made first when it is missing,
    /// and returns what the line under the button says when that failed,
    /// nil when it worked. VoiceOver hears a failure at once; after a
    /// success, Finder's window takes the focus.
    @MainActor
    static func show(
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
