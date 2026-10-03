import Foundation

// MARK: - Where This Mac Keeps Its Library

/// The preferences that say where this Mac keeps its library and which
/// library it expects there (FR02), each defined once. They describe this
/// Mac, so config.json never carries them
/// (`ConfigService.AppConfig.Portability.localStoreKeys`).
///
/// `TextMouthPaths.setCustomRoot` records all three together: the path, a
/// bookmark of the folder beside it, and the identity of the library found
/// there. The library model records the identity again whenever a library
/// opens, and gives one to a library that has none.
enum DataDirectoryPreferences {
    /// The custom data directory's path; absent, or empty, for the default
    /// location. Every release has used this key, so a location chosen
    /// earlier keeps loading.
    static let customPath = StoredPreference<String?>(
        key: "textMouthDataDirectory",
        read: { store, key in store.string(forKey: key) },
        write: { value, store, key in
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// A bookmark of the custom data directory (`URL.bookmarkData`), which
    /// finds the folder again after it is renamed, or after its drive
    /// mounts under another name; absent for the default location.
    static let bookmark = StoredPreference<Data?>(
        key: "textMouthDataDirectoryBookmark",
        read: { store, key in store.data(forKey: key) },
        write: { value, store, key in
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// The identity of the library this Mac expects in its data directory
    /// (`LibraryIdentity.id`), or absent before one is known.
    static let expectedIdentity = StoredPreference<UUID?>(
        key: "textMouthLibraryIdentity",
        read: { store, key in store.string(forKey: key).flatMap(UUID.init(uuidString:)) },
        write: { value, store, key in
            if let value {
                store.set(value.uuidString, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// Every key above, for the machine-local list and for tests that put
    /// them back.
    static let keys = [customPath.key, bookmark.key, expectedIdentity.key]

    /// A bookmark of the folder at `folder`, or nil when there is no folder
    /// there to bookmark yet.
    static func makeBookmark(of folder: URL) -> Data? {
        try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The identity of the library in the folder at `folder`, read without
    /// downloading anything; nil when the folder holds no marker, or one that
    /// can't be read here yet, such as a marker only in the cloud.
    static func identity(in folder: URL) -> LibraryIdentity? {
        DatalessFiles.withoutDownloading {
            try? LibraryIdentity.read(in: folder)
        }
    }
}
