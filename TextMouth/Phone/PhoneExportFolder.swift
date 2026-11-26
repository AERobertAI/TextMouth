import Foundation

/// The folder the iPhone's exports go to (FR31): one the person chose with the
/// system's folder picker, kept as a bookmark in the preferences so that every
/// later export goes there without asking, as the Mac's Choose Folder… keeps
/// its folder.
///
/// A folder outside the app's own container, such as one in iCloud Drive or on
/// the phone's storage, is reached only through the security-scoped URL the
/// picker returned, and through a bookmark made from it
/// (Apple's "Providing access to directories"). A bookmark can go stale, when
/// the folder moves, and can be lost, when the folder is deleted or its
/// provider goes away: the first is made again from the folder as it was
/// found, and the second is forgotten, so the sheet's folder row reads "Choose
/// Folder…" again rather than failing every file.
///
/// A plain type over `UserDefaults`, so the Mac's test host tests it with a
/// sandbox folder, whose bookmark behaves as the phone's does.
struct PhoneExportFolder: Equatable, Sendable {
    /// The preference that holds the bookmark of the folder.
    nonisolated static let bookmarkKey = "phoneExportFolderBookmark"

    /// The folder.
    let url: URL

    /// The folder's name as the system shows it to the person: its localized
    /// name (`URLResourceValues.localizedName`), such as "Downloads" in the
    /// person's language, or the folder's own name when the system gives none.
    /// Used in the folder row and in "Exported 3 items to Downloads.", for
    /// which `FileManager.displayName(atPath:)`, the Mac's, may name an iCloud
    /// Drive folder as its path spells it. Read once, while access to the folder
    /// is held, when the folder is kept or found: outside its scope a folder of
    /// iCloud Drive's may read as its path's last part ("com~apple~CloudDocs"),
    /// so the row and the end of an export, which come later, never ask again.
    let name: String

    /// The folder at `url`, named as it is read now, under its scope.
    init(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        self.init(url: url, name: Self.name(of: url))
    }

    /// The folder at `url` with the name already read.
    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    /// The localized name of the folder at `url`, or its own name when the system gives none. Asks
    /// the file system, so a caller holds access to the folder first (`init(url:)`).
    static func name(of url: URL) -> String {
        let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
        if let localized, !localized.isEmpty { return localized }
        return url.lastPathComponent
    }

    // MARK: - Keeping the Folder

    /// Keeps the folder at `url`, which the picker just returned, as the
    /// folder exports go to. The picker's URL is security-scoped, and a
    /// bookmark is made while access to it is held.
    /// - Returns: The folder kept, or nil when no bookmark could be made of
    ///   it, in which case nothing is kept and the one before is forgotten,
    ///   so a choice that could not be kept is never silently undone later.
    @discardableResult
    static func keep(_ url: URL, in defaults: UserDefaults) -> PhoneExportFolder? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else {
            forget(in: defaults)
            return nil
        }
        defaults.set(data, forKey: bookmarkKey)
        return PhoneExportFolder(url: url, name: Self.name(of: url))
    }

    /// The folder kept, or nil when none is, or when the one kept is lost
    /// (its bookmark no longer resolves, or what it resolves to is gone or is
    /// no longer a folder), which is then forgotten. A stale bookmark of a
    /// folder that is still there is made again and kept.
    static func kept(in defaults: UserDefaults) -> PhoneExportFolder? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale), isFolder(url) else {
            forget(in: defaults)
            return nil
        }
        if isStale {
            keep(url, in: defaults)
        }
        return PhoneExportFolder(url: url)
    }

    /// Forgets the folder kept, so the next export asks for one.
    static func forget(in defaults: UserDefaults) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// Whether `url` is a folder that exists. Access is held while it is
    /// asked, which a folder outside the container needs even to be seen.
    private static func isFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Holding Access

    /// Holds access to the folder from now until the returned closure is
    /// called, which lets it go: an export holds it for its whole run. The
    /// closure does nothing when access was not granted, as it is not for a
    /// folder in the app's own container.
    func holdAccess() -> @Sendable () -> Void {
        Self.holdAccess(to: url)
    }

    /// Holds access to the folder at `url` until the returned closure is called; see `holdAccess()`.
    static func holdAccess(to url: URL) -> @Sendable () -> Void {
        let scoped = url.startAccessingSecurityScopedResource()
        return { if scoped { url.stopAccessingSecurityScopedResource() } }
    }
}
