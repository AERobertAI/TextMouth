import Foundation

/// Where TextMouth writes its diagnostic logs, as Storage settings' Logs
/// group chooses (the user's decision of October 3): inside the data
/// directory, the default, where the logs sit beside the books and are easy
/// to find, or in this Mac's own Logs folder, ~/Library/Logs/TextMouth,
/// which never syncs. config.json mirrors the choice as `logLocation`.
///
/// The log writer reads the choice for every line it writes
/// (`TextMouthPaths.logDestination`), so a change applies to the next line;
/// logs already written stay where they are.
enum LogLocation: String, CaseIterable, Sendable {
    /// The data directory's Logs folder. While the data directory can't take
    /// lines, as while the library isn't available, they go to this Mac's
    /// Logs folder instead, and come back once it can.
    case dataDirectory
    /// This Mac's Logs folder, ~/Library/Logs/TextMouth.
    case machine

    /// The choice in the preferences store, saved as its raw value and read
    /// through `SettingsPolicy.logLocation`, so a missing or unsupported
    /// value reads as the default. The log writer reads it there for every
    /// line; the settings model mirrors it in config.json.
    static let preference = StoredPreference<LogLocation>(
        key: SettingsPolicy.logLocation.key,
        read: { store, key in SettingsPolicy.logLocation.value(fromRaw: store.object(forKey: key) as? String) },
        write: { location, store, key in store.set(location.rawValue, forKey: key) }
    )
}
