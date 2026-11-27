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

    /// Which books this device keeps downloaded (`BooksOnThisDevice`'s raw value, FR45); absent until a
    /// person chooses, which reads as the platform's default. This device's own, so config.json never carries it.
    static let booksOnThisDevice = StoredPreference<String?>(
        key: "textMouthSyncBooksOnThisDevice",
        read: { store, key in store.string(forKey: key) },
        write: { value, store, key in
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// The days a book may stay unopened before its download is removed, 1 to 30, with 0 meaning Off; absent
    /// until a person chooses, which reads as the platform's default (7 on the iPhone, Off on the Mac).
    static let removeAfterDays = StoredPreference<Int?>(
        key: "textMouthSyncRemoveAfterDays",
        read: { store, key in store.object(forKey: key) as? Int },
        write: { value, store, key in
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// When the removal of unopened books began to apply on this device (`SyncDeviceSettings.removalsBeganAt`).
    static let removalsBeganAt = StoredPreference<Date?>(
        key: "textMouthSyncRemovalsBeganAt",
        read: { store, key in store.object(forKey: key) as? Date },
        write: { value, store, key in
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
    )

    /// The books a person freed with Remove Download, each with the time it was freed (seconds since 1970), by the
    /// book's ID: under "All books" such a book is not downloaded again until it is opened (`BooksFreedOnPurpose`).
    static let freedOnPurpose = StoredPreference<[String: Double]>(
        key: "textMouthSyncFreedOnPurpose",
        read: { store, key in store.dictionary(forKey: key) as? [String: Double] ?? [:] },
        write: { value, store, key in
            if value.isEmpty { store.removeObject(forKey: key) } else { store.set(value, forKey: key) }
        }
    )

    /// Every key above, for the machine-local list and for tests that put
    /// them back.
    static let keys = [bookmark.key, storeID.key, installID.key, booksOnThisDevice.key, removeAfterDays.key, removalsBeganAt.key, freedOnPurpose.key]

    /// This install's ID, made and saved on first use.
    static func installIDCreatingIfNeeded(in store: UserDefaults) -> String {
        if let existing = installID.read(from: store), !existing.isEmpty { return existing }
        let made = UUID().uuidString.lowercased()
        installID.write(made, to: store)
        return made
    }
}
