// Phase 0 stand-in: the Mac's LogsInFinder opens the logs folder in Finder and announces a failure; iOS opens nothing and returns a sentence saying it is not available yet.
import Foundation

/// Show Logs in Finder. The iPhone has no Finder, so this stand-in has the
/// Mac's signature (the shared settings and report views call it) and only
/// reports that the feature is not available yet.
enum LogsInFinder {
    /// Opens nothing. Returns the sentence a person hears, "Showing the logs
    /// in Finder is not available on iPhone yet.", as the Mac returns the
    /// failure line under its button. `location` and `open` are unused.
    @MainActor
    static func show(
        for location: LogLocation,
        opening open: (URL) -> Bool = { _ in false }
    ) -> String? {
        IOSUnavailable.feature("Showing the logs in Finder").errorDescription
    }
}
