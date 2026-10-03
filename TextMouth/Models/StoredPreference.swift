import Foundation

// MARK: - A Preference in the Store

/// One preference its owner keeps in a preferences store: the key, and how
/// the owner reads and writes the value there.
///
/// An owner (the sound effects service, the substitution service, the
/// shortcut manager) defines one of these for each preference it saves and
/// does its own reading and writing through it. The settings model mirrors
/// those preferences in config.json through the same definitions, so each
/// key and stored form exists once, with its owner.
struct StoredPreference<Value: Equatable & Sendable>: Sendable {
    /// The key in the preferences store.
    let key: String
    /// Reads the value under the key, or the owner's default when the store
    /// holds nothing the owner can read there.
    private let readValue: @Sendable (_ store: UserDefaults, _ key: String) -> Value
    /// Writes a value under the key, in the form `readValue` reads back.
    private let writeValue: @Sendable (_ value: Value, _ store: UserDefaults, _ key: String) -> Void

    /// A preference saved under `key`. Each closure is given the key, so an
    /// owner names it only once.
    init(
        key: String,
        read: @escaping @Sendable (_ store: UserDefaults, _ key: String) -> Value,
        write: @escaping @Sendable (_ value: Value, _ store: UserDefaults, _ key: String) -> Void
    ) {
        self.key = key
        readValue = read
        writeValue = write
    }

    /// The value `store` holds, as the owner reads it.
    func read(from store: UserDefaults) -> Value {
        readValue(store, key)
    }

    /// Saves `value` to `store`, as the owner saves it.
    func write(_ value: Value, to store: UserDefaults) {
        writeValue(value, store, key)
    }
}

extension StoredPreference where Value == Bool {
    /// A switch saved as a Bool under `key`, reading as `defaultValue` until
    /// one is saved.
    static func flag(_ key: String, default defaultValue: Bool) -> StoredPreference<Bool> {
        StoredPreference(
            key: key,
            read: { store, key in store.object(forKey: key) as? Bool ?? defaultValue },
            write: { value, store, key in store.set(value, forKey: key) }
        )
    }
}

// MARK: - Dictionaries Keyed by Enum Cases

extension Dictionary where Key: RawRepresentable, Key.RawValue == String {
    /// The entries keyed by their keys' raw values: the form the preferences
    /// store and config.json hold a value for each event or action in.
    var keyedByRawValue: [String: Value] {
        Dictionary<String, Value>(uniqueKeysWithValues: map { ($0.key.rawValue, $0.value) })
    }

    /// The entries of `rawKeyed` whose keys name a case; an entry naming
    /// none, such as one a later version saved, is left out.
    init(keyedByRawValue rawKeyed: [String: Value]) {
        self.init(uniqueKeysWithValues: rawKeyed.compactMap { rawKey, value in
            Key(rawValue: rawKey).map { ($0, value) }
        })
    }
}

// MARK: - Following Changes in the Store

/// Calls a handler on the main actor each time one of some keys changes in
/// a preferences store, whoever changed it: the key's owner, the settings
/// model applying config.json, or `defaults write`.
///
/// `UserDefaults` reports changes to individual keys through key-value
/// observing. A change made in this process is reported at once, on the
/// thread that made it, before the write returns, and a write that leaves
/// the value as it was reports nothing. TextMouth writes its preferences on
/// the main thread, so the handler runs within the write. A change another
/// process makes is reported on another thread and handed to the main queue.
///
/// Observing ends when the observer is released.
///
/// `@unchecked Sendable`: its stored properties never change after `init`,
/// `UserDefaults` is documented thread-safe, and the handler is only ever
/// called on the main actor.
final class PreferenceObserver: NSObject, @unchecked Sendable {
    /// The store being observed.
    private let store: UserDefaults
    /// The keys being observed.
    private let keys: [String]
    /// What to do about a change, given the key that changed.
    private let handler: @MainActor (_ key: String) -> Void

    /// Starts observing `keys` in `store`, calling `handler` with each key
    /// that changes.
    init(keys: [String], in store: UserDefaults, handler: @escaping @MainActor (_ key: String) -> Void) {
        self.store = store
        self.keys = keys
        self.handler = handler
        super.init()
        for key in keys {
            store.addObserver(self, forKeyPath: key, options: [], context: context)
        }
    }

    deinit {
        for key in keys {
            store.removeObserver(self, forKeyPath: key, context: context)
        }
    }

    /// Marks this observer's own registrations: its address, which no other
    /// registration can share.
    private var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// Hands a reported change to the handler on the main actor: at once
    /// when it was reported there, otherwise on the main queue's next turn.
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == self.context, let key = keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(key) }
        } else {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { handler(key) }
            }
        }
    }
}
