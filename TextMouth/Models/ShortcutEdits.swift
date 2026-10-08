import Foundation

// MARK: - The Record

/// The keyboard shortcuts the user edited (FR12): each action the user
/// changed, with its keys, and nothing else.
///
/// Every action the record leaves out follows the defaults of the build
/// that runs (`effectiveBindings(defaults:)`), so a default added or changed
/// by a later release reaches every action the user never touched, and never
/// one the user did, as `Book.HandEdits` keeps hand-edited metadata from a
/// refresh. Before the record, the whole map of every action's keys was
/// saved once anything changed, which froze every default of that day: that
/// is how Next Bookmark kept Shift-Command-B after it became Show Bookmarks'.
///
/// An action is edited exactly when the record holds it; an action edited to
/// have no key holds an empty list. Only the user takes an action out: Reset
/// to Default for one, Reset to Defaults for all, or "default" written for
/// it in config.json. So an edited action set back to its default keys stays
/// edited until then, as the user asked on October 7, 2026.
///
/// The preferences store keeps the record under `keyboardShortcutEdits`
/// (`KeyboardShortcutManager.editsPreference`) in the form the whole map was
/// saved in before: JSON keyed by the actions' names, each with its list of
/// keys, holding only the edited actions.
///
/// Shortcuts scoped to a kind of window (FR12's branch E) would give an entry
/// a scope beside its keys: the stored entry, a bare list today, would become
/// an object holding the keys and the scope once the user changes the scope,
/// read in both forms, and `effectiveBindings(defaults:)` would claim each
/// key within the scope its action is given, as it claims it within the
/// app's or the audio editor's today.
struct ShortcutEdits: Equatable, Sendable {
    /// Each edited action's keys, in the order the user gave them.
    private(set) var keysByEditedAction: [ShortcutAction: [KeyBinding]]

    /// A record holding `keys`: each action it names edited, with its keys.
    init(_ keys: [ShortcutAction: [KeyBinding]] = [:]) {
        keysByEditedAction = keys
    }

    /// The edited actions, in the order Settings lists them.
    var editedActions: [ShortcutAction] {
        ShortcutAction.allCases.filter(isEdited)
    }

    /// Whether the user edited `action`'s keys.
    func isEdited(_ action: ShortcutAction) -> Bool {
        keysByEditedAction[action] != nil
    }

    /// The keys the user gave `action`, or nil when the user never edited
    /// it, so it follows the defaults.
    func keys(of action: ShortcutAction) -> [KeyBinding]? {
        keysByEditedAction[action]
    }

    /// Makes `action` the user's with `keys`, each once, and takes each of
    /// them from every other edited action of its scope, which keeps its
    /// other keys and stays edited: no key means two things in one place.
    ///
    /// An unedited action that had one of the keys goes without it while
    /// this action holds it (`effectiveBindings(defaults:)`), and is not made
    /// the user's by losing it; it has the key back once this action lets it
    /// go.
    mutating func setKeys(_ keys: [KeyBinding], for action: ShortcutAction) {
        let given = keys.withoutRepeats
        for other in editedActions where other != action && other.scope == action.scope {
            keysByEditedAction[other]?.removeAll(where: given.contains)
        }
        keysByEditedAction[action] = given
    }

    /// Gives `action` back to the defaults, as Reset to Default does.
    mutating func reset(_ action: ShortcutAction) {
        keysByEditedAction[action] = nil
    }

    /// Every action's keys in force, given a build's `defaults`
    /// (`ShortcutAction.defaultBindings`): an edited action has its own
    /// keys, and every other action its defaults less any key an edited
    /// action of its scope holds.
    ///
    /// The actions claim their keys in the order Settings lists them, the
    /// edited ones first, so no key ever belongs to two actions of one scope
    /// here, whatever the record holds. Every change keeps one owner for
    /// each key, so two edited actions can hold one only in a store edited
    /// by hand; the one Settings lists first then keeps it, the rule
    /// config.json's own conflicts follow (`resolvingSharedKeys(favoring:)`).
    func effectiveBindings(defaults: [ShortcutAction: [KeyBinding]]) -> [ShortcutAction: [KeyBinding]] {
        var claimed: [ShortcutScope: Set<KeyBinding>] = [:]
        var bindings: [ShortcutAction: [KeyBinding]] = [:]
        // The keys of `keys` no action of `action`'s scope has claimed yet,
        // each claimed for `action` as it is kept.
        func claim(_ keys: [KeyBinding], for action: ShortcutAction) -> [KeyBinding] {
            keys.filter { claimed[action.scope, default: []].insert($0).inserted }
        }
        // The edited actions claim their keys first, so that no default, a
        // later release's new one included, ever takes one of them.
        for action in editedActions {
            bindings[action] = claim(keysByEditedAction[action] ?? [], for: action)
        }
        for action in ShortcutAction.allCases where !isEdited(action) {
            bindings[action] = claim(defaults[action] ?? [], for: action)
        }
        return bindings
    }
}

// MARK: - A Key Two Edited Actions Hold

extension ShortcutEdits {
    /// A key two edited actions of one scope held, which only an edit of
    /// config.json or the move from the old saved map can give, and the
    /// action left holding it.
    struct SharedKey: Equatable, Sendable {
        /// The key.
        let key: KeyBinding
        /// The action that keeps it.
        let keeper: ShortcutAction
        /// The action that goes without it, keeping its other keys, still
        /// edited.
        let loser: ShortcutAction
    }

    /// A record with each key two edited actions held left to one of them,
    /// and every key so settled, in the order they were found.
    typealias Settlement = (edits: ShortcutEdits, sharedKeys: [SharedKey])

    /// The record with every key that two or more edited actions of one
    /// scope hold left to one of them (FR12, section 5.2 of the design), and
    /// each key so settled.
    ///
    /// The holder whose entry is in `changed` keeps the key, as recording a
    /// key in Settings takes it for the action recorded. When several
    /// holders changed, or none did (a file edited while TextMouth was closed
    /// that lists one key twice), the one Settings lists first keeps it.
    /// Every other holder goes without that key, keeps its other keys, and
    /// stays edited.
    func resolvingSharedKeys(favoring changed: Set<ShortcutAction>) -> Settlement {
        // Each key's holders in the order Settings lists them, and the keys
        // in the order they are first held, so the result is the same at
        // every launch.
        var holders: [ScopedKey: [ShortcutAction]] = [:]
        var order: [ScopedKey] = []
        for action in editedActions {
            for key in keysByEditedAction[action] ?? [] {
                let scoped = ScopedKey(scope: action.scope, key: key)
                if holders[scoped] == nil {
                    order.append(scoped)
                }
                if holders[scoped]?.contains(action) != true {
                    holders[scoped, default: []].append(action)
                }
            }
        }
        var settled = self
        var sharedKeys: [SharedKey] = []
        for scoped in order {
            guard let actions = holders[scoped], actions.count > 1 else { continue }
            let favored = actions.filter(changed.contains)
            guard let keeper = (favored.isEmpty ? actions : favored).first else { continue }
            for loser in actions where loser != keeper {
                settled.keysByEditedAction[loser]?.removeAll { $0 == scoped.key }
                sharedKeys.append(SharedKey(key: scoped.key, keeper: keeper, loser: loser))
            }
        }
        return (settled, sharedKeys)
    }
}

/// A key within one scope, as the keys two actions hold are found.
private struct ScopedKey: Hashable {
    let scope: ShortcutScope
    let key: KeyBinding
}

// MARK: - The Move From the Whole Saved Map

extension ShortcutEdits {
    /// The record made, once, from the shortcuts saved before it existed
    /// (FR12, section 4.2 of the design), and every key it found on two
    /// edited actions, left to one of them.
    ///
    /// Each action is decided in the order Settings lists them:
    /// 1. Its keys are config.json's when they differ from the saved map's:
    ///    the old releases wrote the two together, so a difference is an
    ///    edit made in the file while TextMouth was closed. Otherwise they
    ///    are the saved map's, and without a saved map the file's, which the
    ///    old release wrote from its defaults. An action neither lists, such
    ///    as one added since, is unedited.
    /// 2. It is unedited when those keys are its default, today's or one it
    ///    had before, whole or less the keys other actions of its scope hold
    ///    among the keys of step 1: a key the user gave another action leaves
    ///    this one without it, and does not make it the user's. From then on
    ///    it follows the defaults, where counting it edited would freeze an
    ///    old default, as the whole-map save did.
    /// 3. Otherwise it is edited, with those keys.
    /// 4. A key two edited actions then hold goes to the one whose keys came
    ///    from an edit of the file, else to the one Settings lists first
    ///    (`resolvingSharedKeys(favoring:)`).
    ///
    /// The order of an action's keys is no edit: keys are compared as sets.
    ///
    /// - Parameters:
    ///   - savedMap: Every action's keys as the store's whole map held them
    ///     (`customKeyboardBindings`), or nil for a user who never changed a
    ///     shortcut, whose store holds none.
    ///   - fileLists: Every action's keys as config.json listed them in its
    ///     old form, or nil without a file to read.
    ///   - defaults: Today's defaults.
    ///   - formerDefaults: The defaults actions had before today's.
    static func migrating(
        savedMap: [ShortcutAction: [KeyBinding]]?,
        fileLists: [ShortcutAction: [KeyBinding]]?,
        defaults: [ShortcutAction: [KeyBinding]] = ShortcutAction.defaultBindings,
        formerDefaults: [ShortcutAction: [[KeyBinding]]] = ShortcutAction.formerDefaultBindings
    ) -> Settlement {
        // Step 1: each action's keys, and the actions an edit of the file
        // made while TextMouth was closed.
        var keys = savedMap ?? [:]
        var editedInFile: Set<ShortcutAction> = []
        for (action, listed) in fileLists ?? [:] {
            guard let saved = savedMap?[action] else {
                keys[action] = listed
                continue
            }
            if saved != listed {
                keys[action] = listed
                editedInFile.insert(action)
            }
        }
        // Steps 2 and 3: the actions whose keys are no default of theirs.
        var edited: [ShortcutAction: [KeyBinding]] = [:]
        for action in ShortcutAction.allCases {
            guard let actionKeys = keys[action] else { continue }
            let heldElsewhere = Set(keys.lazy.filter { $0.key != action && $0.key.scope == action.scope }.flatMap(\.value))
            let given = Set(actionKeys)
            let isADefault = ([defaults[action] ?? []] + (formerDefaults[action] ?? [])).contains { aDefault in
                given == Set(aDefault) || given == Set(aDefault.filter { !heldElsewhere.contains($0) })
            }
            if !isADefault {
                edited[action] = actionKeys.withoutRepeats
            }
        }
        // Step 4.
        return ShortcutEdits(edited).resolvingSharedKeys(favoring: editedInFile)
    }
}

// MARK: - In config.json

extension ShortcutEdits {
    /// Every action's entry as config.json lists it (FR12, section 5.1 of
    /// the design), given a build's `defaults`: an edited action's keys in
    /// force as a list, and every other action "default: " and its keys in
    /// force (`ShortcutListing`). An edited action set back to its default
    /// keys is still a list: it stays the user's.
    func listings(defaults: [ShortcutAction: [KeyBinding]]) -> [ShortcutAction: ShortcutListing] {
        let inForce = effectiveBindings(defaults: defaults)
        var listings: [ShortcutAction: ShortcutListing] = [:]
        for action in ShortcutAction.allCases {
            let keys = inForce[action] ?? []
            listings[action] = isEdited(action) ? .edited(keys) : .followingDefaults(keys)
        }
        return listings
    }

    /// The record once config.json's `listings` are in place (FR12, sections
    /// 5.1 and 5.2 of the design), and every key two edited actions then
    /// held, left to one of them.
    ///
    /// A list makes its action the user's with those keys, even keys equal
    /// to its default; text beginning with "default" gives it back to the
    /// defaults, as Reset to Default does; an action the listings leave out,
    /// or whose entry cannot be read, keeps what it has. A key two edited
    /// actions then hold goes to the one whose entry changed the record, as
    /// recording a key in Settings takes it for the action recorded, and
    /// when both or neither did, to the one Settings lists first
    /// (`resolvingSharedKeys(favoring:)`).
    func adopting(_ listings: [ShortcutAction: ShortcutListing]) -> Settlement {
        var adopted = self
        var changed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let listing = listings[action] else { continue }
            if listing.followsDefaults {
                if adopted.keysByEditedAction.removeValue(forKey: action) != nil {
                    changed.insert(action)
                }
            } else if let keys = listing.bindings?.withoutRepeats, adopted.keysByEditedAction[action] != keys {
                adopted.keysByEditedAction[action] = keys
                changed.insert(action)
            }
        }
        return adopted.resolvingSharedKeys(favoring: changed)
    }
}

// MARK: - In the Preferences Store

extension ShortcutEdits {
    /// The record as the preferences store keeps it: JSON keyed by the
    /// edited actions' names, each with its list of keys, the form the whole
    /// map was saved in before the record. Its entries are written in sorted
    /// order, so one record is always the same bytes, and saving it again
    /// changes nothing in the store. Nil only should encoding fail, which
    /// leaves the store as it was.
    var storedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(keysByEditedAction.keyedByRawValue)
    }

    /// An entry of stored shortcuts left out as they were read, and why.
    struct SkippedEntry: Equatable, Sendable {
        /// The entry's name as stored, or nil when nothing could be read.
        let name: String?
        /// Why it was left out, as the repair log line says it.
        let reason: String
    }

    /// What reading stored shortcuts found.
    struct StoredReading: Equatable, Sendable {
        /// The record: every entry that could be used.
        let edits: ShortcutEdits
        /// Every entry left out, in the order of their names.
        let skipped: [SkippedEntry]
    }

    /// Reads shortcuts stored as `storedData` writes them, entry by entry,
    /// as `Book.HandEdits` is read: an entry naming no action this build
    /// knows, such as one a later release wrote, and an entry whose keys
    /// cannot be read are left out and reported, and the rest still load.
    /// Data that is not such an object at all reads as an empty record.
    ///
    /// The whole map every release before the record saved is in the same
    /// form, so this reads it too, for the move to the record: each action
    /// it lists, with its keys.
    static func reading(_ data: Data) -> StoredReading {
        guard let entries = try? JSONDecoder().decode([String: LenientStoredKeys].self, from: data) else {
            let unreadable = SkippedEntry(name: nil, reason: "could not be read as keyboard shortcuts; using none")
            return StoredReading(edits: ShortcutEdits(), skipped: [unreadable])
        }
        var keys: [ShortcutAction: [KeyBinding]] = [:]
        var skipped: [SkippedEntry] = []
        // In the order of their names, so the entries left out are reported
        // in the same order every time.
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let action = ShortcutAction(rawValue: name) else {
                skipped.append(SkippedEntry(name: name, reason: "names nothing TextMouth knows; leaving it out"))
                continue
            }
            guard let actionKeys = entry.keys else {
                skipped.append(SkippedEntry(name: name, reason: "could not be read as a list of shortcuts; leaving it out"))
                continue
            }
            keys[action] = actionKeys
        }
        return StoredReading(edits: ShortcutEdits(keys), skipped: skipped)
    }
}

/// One stored entry's keys, or nil when they cannot be read, so that one
/// entry never fails the others.
private struct LenientStoredKeys: Decodable {
    /// The entry's keys, or nil.
    let keys: [KeyBinding]?

    /// Reads the entry's value as a list of keys, or nil for anything else.
    init(from decoder: Decoder) throws {
        keys = try? decoder.singleValueContainer().decode([KeyBinding].self)
    }
}

// MARK: - Repairs in the Debug Log

extension ShortcutEdits {
    /// Writes one STORED_VALUE_REPAIRED line to the debug log for each entry
    /// of `field` in `source` left out as it was read, such as
    /// "preferences keyboardShortcutEdits.Teleport: names nothing TextMouth
    /// knows; leaving it out".
    static func log(_ skipped: [SkippedEntry], source: String, field: String) {
        for entry in skipped {
            StoredValueRepair.log(
                source: source,
                codingPath: [LoggedName(field)] + (entry.name.map { [LoggedName($0)] } ?? []),
                detail: entry.reason
            )
        }
    }

    /// Writes one STORED_VALUE_REPAIRED line to the debug log for each key
    /// two edited actions held in `field` of `source`, naming the key, the
    /// action that keeps it, and the one that goes without it, such as
    /// "config.json keyboardShortcuts.Show Bookmarks: shared
    /// "shift+command+b" with "Next Bookmark", which keeps it; "Show
    /// Bookmarks" goes without it".
    static func log(_ sharedKeys: [SharedKey], source: String, field: String) {
        for shared in sharedKeys {
            StoredValueRepair.log(
                source: source,
                codingPath: [LoggedName(field), LoggedName(shared.loser.rawValue)],
                detail: "shared \"\(shared.key.configText)\" with \"\(shared.keeper.rawValue)\", which keeps it; "
                    + "\"\(shared.loser.rawValue)\" goes without it"
            )
        }
    }
}

/// Names a field, or an entry within it, in a repair log line: the parts of
/// "keyboardShortcuts.Show Bookmarks".
private struct LoggedName: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    /// The name `name`.
    init(_ name: String) {
        stringValue = name
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// Entries are named by text, never by position.
    init?(intValue: Int) {
        nil
    }
}

// MARK: - Helpers

private extension Array where Element == KeyBinding {
    /// The keys, each once, in the order first given.
    var withoutRepeats: [KeyBinding] {
        var seen = Set<KeyBinding>()
        return filter { seen.insert($0).inserted }
    }
}
