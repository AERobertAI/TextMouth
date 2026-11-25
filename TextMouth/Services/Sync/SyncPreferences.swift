import Foundation

// MARK: - The Sync Preferences (FR43)

/// The preferences that say which sync folder this device uses and which
/// install it is, each defined once. They describe this device, so
/// config.json never carries them
/// (`ConfigService.AppConfig.Portability.localStoreKeys`), shaped as
/// `DataDirectoryPreferences`.
enum SyncPreferences {
    /// A bookmark of the TextMouth Sync folder (`URL.bookmarkData`), which
    /// finds the folder again after a rename or a remount; absent while sync
    /// is off.
    static let bookmark = StoredPreference<Data?>(
        key: "textMouthSyncFolderBookmark",
        read: { store, key in store.data(forKey: key) },
        write: { value, store, key in
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// The ID of the store this device joined (`SyncStoreFile.storeID`);
    /// absent while sync is off.
    static let storeID = StoredPreference<UUID?>(
        key: "textMouthSyncStoreID",
        read: { store, key in store.string(forKey: key).flatMap(UUID.init(uuidString:)) },
        write: { value, store, key in
            if let value { store.set(value.uuidString, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// An ID made once per install, so a library restored onto another
    /// install is told from a copy on the same one; absent until sync is
    /// first set up.
    static let installID = StoredPreference<String?>(
        key: "textMouthSyncInstallID",
        read: { store, key in store.string(forKey: key) },
        write: { value, store, key in
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// Every key above, for the machine-local list and for tests that put
    /// them back.
    static let keys = [bookmark.key, storeID.key, installID.key]

    /// This install's ID, made and saved on first use.
    static func installIDCreatingIfNeeded(in store: UserDefaults) -> String {
        if let existing = installID.read(from: store), !existing.isEmpty { return existing }
        let made = UUID().uuidString.lowercased()
        installID.write(made, to: store)
        return made
    }
}
