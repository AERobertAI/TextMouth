import Combine
import Foundation

/// The Library's views, as the preferences store keeps them under
/// "libraryViews" and config.json mirrors them (the design of October 30,
/// 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 8): what Library
/// windows and the Library settings tab read and change.
///
/// The preferences store holds the same JSON array config.json does, so an
/// older TextMouth, which drops the key from config.json at its next save,
/// loses nothing: this Mac's store keeps the list, a config.json without the
/// key changes no preference, and the next save writes the list back. The
/// settings model mirrors the key in config.json like every portable
/// preference (`SettingsViewModel.servicePreferenceKeys`).
@MainActor
final class LibraryViewDefinitionStore: ObservableObject {
    /// The store the app uses, on its preferences
    /// (`TextMouthRuntime.current.preferences`), which a process hosting
    /// tests keeps in its own sandbox.
    static let shared = LibraryViewDefinitionStore(preferences: TextMouthRuntime.current.preferences)

    /// The list in the preferences store: the JSON array config.json holds,
    /// as data written with sorted keys, or the shipped list while none is
    /// saved or what is saved is not a JSON array. Reading it logs nothing:
    /// TextMouth wrote what the store holds, and config.json's own reading
    /// logs the repairs of a hand edit.
    nonisolated static let preference = StoredPreference<LibraryViewDefinitionList>(
        key: LibraryViewDefinitionList.fileKey,
        read: { store, key in
            guard let data = store.data(forKey: key),
                  let entries = try? JSONDecoder().decode([JSONValue].self, from: data) else {
                return .shipped
            }
            return LibraryViewDefinitionList(fileEntries: entries)
        },
        write: { list, store, key in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(list.fileEntries) else { return }
            store.set(data, forKey: key)
        }
    )

    /// The list now, published only when it changes.
    @Published private(set) var list: LibraryViewDefinitionList

    /// The preferences the list is kept in.
    private let preferences: UserDefaults
    /// Follows the key in `preferences`, so a change made by any writer
    /// reaches `list`.
    private var observer: PreferenceObserver?

    /// A store reading and writing `preferences`, following every change of
    /// the key there, whoever makes it (the settings model applying
    /// config.json, or another store on the same preferences), so `list`
    /// always shows what is saved.
    init(preferences: UserDefaults) {
        self.preferences = preferences
        list = Self.preference.read(from: preferences)
        observer = PreferenceObserver(keys: [Self.preference.key], in: preferences) { [weak self] _ in
            self?.reload()
        }
    }

    /// Changes the list with `change`, saves it when it changed, and returns
    /// what `change` returned, such as an operation's Bool, for the words
    /// VoiceOver says after it. A change that leaves the list as it was
    /// writes and publishes nothing.
    @discardableResult
    func update<Result>(_ change: (inout LibraryViewDefinitionList) -> Result) -> Result {
        var changed = list
        let result = change(&changed)
        if changed != list {
            list = changed
            Self.preference.write(changed, to: preferences)
        }
        return result
    }

    /// Reads the list again after its key changed, publishing it only when
    /// it differs from the one shown, as when this store's own write is
    /// reported back.
    private func reload() {
        let saved = Self.preference.read(from: preferences)
        if saved != list {
            list = saved
        }
    }
}
