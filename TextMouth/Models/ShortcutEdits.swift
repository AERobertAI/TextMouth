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
/// An edited action may work in a kind of window the user chose (FR12's
/// branch E): the record keeps the scope beside its keys only when it is
/// not the action's default, so an action edited for its keys alone follows
/// its default scope, and Reset to Default gives back both.
///
/// The preferences store keeps the record under `keyboardShortcutEdits`
/// (`KeyboardShortcutManager.editsPreference`) in the form the whole map was
/// saved in before: JSON keyed by the actions' names, each with its list of
/// keys, holding only the edited actions; an action working in a scope the
/// user chose is an object holding its keys and the scope instead, as
/// `{"keys": [...], "worksIn": "library"}`. Both forms are read. config.json
/// lists every action (`listings(defaults:)`), in forms of its own
/// (`ShortcutListing`).
struct ShortcutEdits: Equatable, Sendable {
    /// Each edited action's keys, in the order the user gave them.
    private(set) var keysByEditedAction: [ShortcutAction: [KeyBinding]]
    /// The scope each edited action works in when the user chose one other
    /// than its default (FR12's branch E); an edited action left out works
    /// where its default scope reaches.
    private(set) var scopesByEditedAction: [ShortcutAction: ShortcutScope]

    /// A record holding `keys`: each action it names edited, with its keys,
    /// working where `scopes` says. A scope is kept only for an action the
    /// record holds, only when the action may be given it
    /// (`ShortcutAction.availableScopes`), and only when it is not the
    /// action's default.
    init(_ keys: [ShortcutAction: [KeyBinding]] = [:], scopes: [ShortcutAction: ShortcutScope] = [:]) {
        keysByEditedAction = keys
        scopesByEditedAction = scopes.filter { action, scope in
            keys[action] != nil && scope != action.defaultScope && action.availableScopes.contains(scope)
        }
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

    /// Makes `action` the user's with `keys`, each once, and takes from
    /// every other edited action each key that clashes with one of them
    /// (`key(_:of:clashesWith:of:)`); that action keeps its other keys and
    /// stays edited: no key means two things in one place.
    ///
    /// An unedited action that had one of the keys goes without it while
    /// this action holds it (`effectiveBindings(defaults:)`), and is not made
    /// the user's by losing it; it has the key back once this action lets it
    /// go.
    mutating func setKeys(_ keys: [KeyBinding], for action: ShortcutAction) {
        let given = keys.withoutRepeats
        for other in editedActions where other != action {
            guard let held = keysByEditedAction[other] else { continue }
            // Worked out before the record changes, which the clash rule reads.
            let kept = held.filter { heldKey in
                !given.contains { key(heldKey, of: other, clashesWith: $0, of: action) }
            }
            keysByEditedAction[other] = kept
        }
        keysByEditedAction[action] = given
    }

    /// Whether `key`, held by `action`, and `otherKey`, held by `other`,
    /// cannot both be in force: where both actions act (in a kind of window
    /// their scopes share, FR12's branch E, a menu command's key acting
    /// wherever its menu item does, `ShortcutAction.sharesAWindow`), the
    /// same key, or, when either is a key equivalent, one key's single and
    /// double press (FR12's branch D). A menu or button takes a key's first
    /// press, so a double press of a key equivalent's key would never reach
    /// the shortcut manager, and a double press's first press, which the
    /// manager takes, would never reach the menu (`KeyClaims.forms(of:for:)`).
    func key(_ key: KeyBinding, of action: ShortcutAction, clashesWith otherKey: KeyBinding, of other: ShortcutAction) -> Bool {
        guard action.sharesAWindow(in: scope(of: action), with: other, in: scope(of: other)) else { return false }
        let forms = KeyClaims.forms(of: key, for: action)
        return KeyClaims.forms(of: otherKey, for: other).contains(where: forms.contains)
    }

    /// Where `action`'s shortcuts work (FR12's branch E): the scope the user
    /// chose, or its default.
    func scope(of action: ShortcutAction) -> ShortcutScope {
        scopesByEditedAction[action] ?? action.defaultScope
    }

    /// Makes `action` the user's, working in `scope`, with `keys`, its keys
    /// in force as the Shortcuts tab gives them (FR12's branch E): each key
    /// that clashes with another edited action's where both now work is
    /// taken from that action, which keeps its other keys and stays edited,
    /// as recording a key takes it (`setKeys(_:for:)`). A scope the action
    /// may not be given changes nothing.
    mutating func setScope(_ scope: ShortcutScope, for action: ShortcutAction, keys: [KeyBinding]) {
        guard action.availableScopes.contains(scope) else { return }
        scopesByEditedAction[action] = scope == action.defaultScope ? nil : scope
        setKeys(keys, for: action)
    }

    /// Every action's scope in force, for the press index.
    var scopesInForce: [ShortcutAction: ShortcutScope] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, scope(of: $0)) })
    }

    /// Gives `action` back to the defaults, its keys and its scope, as Reset
    /// to Default does.
    mutating func reset(_ action: ShortcutAction) {
        keysByEditedAction[action] = nil
        scopesByEditedAction[action] = nil
    }

    /// Every action's keys in force, given a build's `defaults`
    /// (`ShortcutAction.defaultBindings`): an edited action has its own
    /// keys, and every other action its defaults less any key an edited
    /// action whose scope overlaps its own holds.
    ///
    /// The actions claim their keys in the order Settings lists them, the
    /// edited ones first, so no key ever belongs to two actions in one kind
    /// of window here, whatever the record holds; a key equivalent's key
    /// counts as pressed once and twice (`KeyClaims`). Every change keeps one
    /// owner for each key, so two edited actions can hold one only in a store
    /// edited by hand; the one Settings lists first then keeps it, the rule
    /// config.json's own conflicts follow (`resolvingSharedKeys(favoring:)`).
    func effectiveBindings(defaults: [ShortcutAction: [KeyBinding]]) -> [ShortcutAction: [KeyBinding]] {
        var claims = KeyClaims()
        var bindings: [ShortcutAction: [KeyBinding]] = [:]
        // The keys of `keys` that clash with no key claimed yet, each
        // claimed for `action` as it is kept.
        func claim(_ keys: [KeyBinding], for action: ShortcutAction) -> [KeyBinding] {
            keys.filter { claims.claim($0, for: action, in: scope(of: action)) == nil }
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

// MARK: - One Owner for Each Key

/// The keys claimed so far, each for one action, as the keys in force are
/// handed out and as a key two edited actions hold is settled (FR12): a key
/// that clashes with one claimed where both actions work goes without.
///
/// Keys are claimed in each kind of window where an action's keys act in its
/// scope (FR12's branch E, `ShortcutScope.windowKinds(of:)`): those its
/// scope reaches, and for a menu command every kind its menu item acts in,
/// an audio editor's included for one working in every window (REV11). A
/// key claimed in any of them is lost to every later action acting in that
/// kind: an action's key works wherever its keys act, or it goes without it.
///
/// A key equivalent's key stands for its stroke pressed once and pressed
/// twice (`forms(of:for:)`, FR12's branch D), since a menu or button takes
/// a key's first press: no other action may have the key's double press, nor
/// the key itself. A single press and a double press of one key held by
/// two other actions are no clash; the shortcut manager tells them apart.
struct KeyClaims {
    /// A key claimed: the action it was claimed for, and the key as that
    /// action holds it.
    struct Holder: Equatable {
        let action: ShortcutAction
        let key: KeyBinding
    }

    /// Each kind of window's claimed keys, each form of a key with its
    /// holder.
    private var holders: [ShortcutWindowKind: [KeyBinding: Holder]] = [:]

    /// The keys `key` of `action` stands for: itself, or, for a key
    /// equivalent's action, its stroke pressed once and twice.
    static func forms(of key: KeyBinding, for action: ShortcutAction) -> [KeyBinding] {
        action.isKeyEquivalent ? [key.stroke, key.stroke.asDoublePress(true)] : [key]
    }

    /// Claims `key` for `action` in every kind of window where its keys act
    /// in `scope` (`ShortcutScope.windowKinds(of:)`), unless a key clashing
    /// with it is claimed in one of them already. Returns nil once claimed,
    /// or the holder of the clashing key, found in the kinds in their fixed
    /// order, which keeps it.
    mutating func claim(_ key: KeyBinding, for action: ShortcutAction, in scope: ShortcutScope) -> Holder? {
        let forms = Self.forms(of: key, for: action)
        let actsIn = scope.windowKinds(of: action)
        let kinds = ShortcutWindowKind.allCases.filter(actsIn.contains)
        for kind in kinds {
            let claimedThere = holders[kind] ?? [:]
            if let holder = forms.compactMap({ claimedThere[$0] }).first {
                return holder
            }
        }
        for kind in kinds {
            for form in forms {
                holders[kind, default: [:]][form] = Holder(action: action, key: key)
            }
        }
        return nil
    }
}

// MARK: - A Key Two Edited Actions Hold

extension ShortcutEdits {
    /// A key two edited actions whose scopes overlap held, which only an edit of
    /// config.json or the move from the old saved map can give, and the
    /// action left holding it.
    struct SharedKey: Equatable, Sendable {
        /// The key, as the action that goes without it held it.
        let key: KeyBinding
        /// The action that keeps it.
        let keeper: ShortcutAction
        /// The action that goes without it, keeping its other keys, still
        /// edited.
        let loser: ShortcutAction
        /// The keeper's key when it is not the same key but clashes with it:
        /// a key equivalent's key and the same key pressed twice (FR12's
        /// branch D); nil when the two held one key.
        var keepersKey: KeyBinding? = nil
    }

    /// A record with each key two edited actions held left to one of them,
    /// and every key so settled, in the order they were found.
    typealias Settlement = (edits: ShortcutEdits, sharedKeys: [SharedKey])

    /// The record with every key that clashes with another edited action's
    /// left to one of them (FR12, section 5.2 of the design): the same key
    /// where both actions work, or a key equivalent's key and the same key
    /// pressed twice.
    /// Each key so settled is returned too.
    ///
    /// The holder whose entry is in `changed` keeps the key, as recording a
    /// key in Settings takes it for the action recorded. When several
    /// holders changed, or none did (a file edited while TextMouth was closed
    /// that lists one key twice), the one Settings lists first keeps it.
    /// Every other holder goes without that key, keeps its other keys, and
    /// stays edited. The keys settled are listed by the actions that lost
    /// them, in the order Settings lists those, so the result is the same at
    /// every launch.
    func resolvingSharedKeys(favoring changed: Set<ShortcutAction>) -> Settlement {
        // The changed holders claim their keys first, then every other, each
        // group in Settings order; a key clashing with one claimed is lost.
        let claimingOrder = editedActions.filter(changed.contains) + editedActions.filter { !changed.contains($0) }
        var claims = KeyClaims()
        var settled = self
        var sharedKeys: [SharedKey] = []
        for action in claimingOrder {
            for key in keysByEditedAction[action] ?? [] {
                // One action's own keys never clash with each other here.
                guard let keeper = claims.claim(key, for: action, in: scope(of: action)), keeper.action != action else { continue }
                settled.keysByEditedAction[action]?.removeAll { $0 == key }
                sharedKeys.append(SharedKey(
                    key: key,
                    keeper: keeper.action,
                    loser: action,
                    keepersKey: keeper.key == key ? nil : keeper.key
                ))
            }
        }
        // By the losers' places in Settings, and, for one loser, in the
        // order it held its keys.
        let rank = ShortcutAction.settingsRank
        let ordered = sharedKeys.enumerated().sortedStably { first, second in
            let ranks = (rank[first.element.loser, default: 0], rank[second.element.loser, default: 0])
            return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : first.offset < second.offset
        }
        return (settled, ordered.map(\.element))
    }
}

extension ShortcutAction {
    /// Each action's place in the order Settings lists them, from 0.
    static let settingsRank: [ShortcutAction: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) }
    )
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
    ///    had before, whole or less the keys other actions whose scopes
    ///    overlap its own hold
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
            let isADefault = keysAreADefault(
                of: action, given: actionKeys, among: keys, defaults: defaults, formerDefaults: formerDefaults
            )
            if !isADefault {
                edited[action] = actionKeys.withoutRepeats
            }
        }
        // Step 4.
        return ShortcutEdits(edited).resolvingSharedKeys(favoring: editedInFile)
    }

    /// Whether the `given` keys of `action` count as no edit: they are its
    /// default, today's or one it had before, whole or less the keys other
    /// actions whose scopes overlap its own hold among `keys`. A key the
    /// user gave another action leaves this one without it, and does not
    /// make it the user's. The rule of steps 2 and 3 of `migrating`, which
    /// also judges an old-form config.json read after the move
    /// (`KeyboardShortcutManager.adopt(_:in:)`), so the two cannot differ.
    ///
    /// The order of the keys is no edit: they are compared as sets.
    ///
    /// - Parameters:
    ///   - action: The action whose keys are judged.
    ///   - given: The keys `action` was given.
    ///   - keys: Every action's keys, those other actions hold being what
    ///     `action` may have lost.
    ///   - defaults: Today's defaults.
    ///   - formerDefaults: The defaults actions had before today's.
    static func keysAreADefault(
        of action: ShortcutAction,
        given: [KeyBinding],
        among keys: [ShortcutAction: [KeyBinding]],
        defaults: [ShortcutAction: [KeyBinding]] = ShortcutAction.defaultBindings,
        formerDefaults: [ShortcutAction: [[KeyBinding]]] = ShortcutAction.formerDefaultBindings
    ) -> Bool {
        // The keys other actions working in a window of this action's hold.
        let heldElsewhere = Set(keys.lazy.filter { other, _ in
            other != action && other.sharesAWindow(in: other.defaultScope, with: action, in: action.defaultScope)
        }.flatMap(\.value))
        let givenSet = Set(given)
        return ([defaults[action] ?? []] + (formerDefaults[action] ?? [])).contains { aDefault in
            givenSet == Set(aDefault) || givenSet == Set(aDefault.filter { !heldElsewhere.contains($0) })
        }
    }
}

// MARK: - In config.json

extension ShortcutEdits {
    /// Every action's entry as config.json lists it (FR12, section 5.1 of
    /// the design), given a build's `defaults` (`ShortcutListing`): an
    /// edited action's keys in force as a list, or, for one working in a
    /// scope the user chose, as an object holding them and that scope (FR12's
    /// branch E); and every other action "default: " and its keys in force,
    /// naming its default scope when that is said, as in "default in reader
    /// windows: shift+command+t". An edited action set back to its default
    /// keys is still a list: it stays the user's.
    func listings(defaults: [ShortcutAction: [KeyBinding]]) -> [ShortcutAction: ShortcutListing] {
        let inForce = effectiveBindings(defaults: defaults)
        var listings: [ShortcutAction: ShortcutListing] = [:]
        for action in ShortcutAction.allCases {
            let keys = inForce[action] ?? []
            if !isEdited(action) {
                listings[action] = .followingDefaults(keys, worksIn: action.defaultScope)
            } else if let scope = scopesByEditedAction[action] {
                listings[action] = .edited(keys, worksIn: scope)
            } else {
                listings[action] = .edited(keys)
            }
        }
        return listings
    }

    /// The record once config.json's `listings` are in place (FR12, sections
    /// 5.1 and 5.2 of the design), and every key two edited actions then
    /// held, left to one of them.
    ///
    /// A list makes its action the user's with those keys, even keys equal
    /// to its default, working where it does by default (a file in the old
    /// form, a list for every action, is first stripped of the lists equal
    /// to a default: `KeyboardShortcutManager.adopt(_:in:)`); an object makes it
    /// the user's with its keys, working in the kind of window it names
    /// (FR12's branch E); text beginning with "default" gives it back to the
    /// defaults, its keys and its scope, as Reset to Default does. An action
    /// the listings leave out, or whose entry cannot be read or names a kind
    /// of window it cannot work in (`entriesLeftOut(of:)`), keeps what it
    /// has. A key two edited actions whose scopes then overlap hold goes to
    /// the one whose entry changed the record, as recording a key in
    /// Settings takes it for the action recorded, and when both or neither
    /// did, to the one Settings lists first (`resolvingSharedKeys(favoring:)`).
    func adopting(_ listings: [ShortcutAction: ShortcutListing]) -> Settlement {
        var adopted = self
        var changed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let listing = listings[action] else { continue }
            if listing.followsDefaults {
                // Its keys and its scope, as Reset to Default gives back.
                if adopted.isEdited(action) {
                    adopted.reset(action)
                    changed.insert(action)
                }
                continue
            }
            guard let keys = listing.bindings?.withoutRepeats,
                  let scope = listing.scope(for: action),
                  action.availableScopes.contains(scope) else { continue }
            if adopted.keysByEditedAction[action] != keys || adopted.scope(of: action) != scope {
                adopted.keysByEditedAction[action] = keys
                adopted.scopesByEditedAction[action] = scope == action.defaultScope ? nil : scope
                changed.insert(action)
            }
        }
        return adopted.resolvingSharedKeys(favoring: changed)
    }

    /// Why an entry of config.json is left out, its action keeping what it
    /// has (FR12's branches D and E).
    enum LeftOutEntry: Equatable, Sendable {
        /// The entry names a kind of window its action cannot work in.
        case cannotWorkIn(ShortcutScope)
        /// The entry gives its action keys it cannot take.
        case refused(ShortcutRefusal)

        /// Why, as the repair log says it: "works in reader windows, which
        /// it cannot", or ""w" cannot be its shortcut: a menu command's
        /// shortcut is one press of a key with Command or Control".
        var reason: String {
            switch self {
            case .cannotWorkIn(let scope):
                return "works in \(scope.inSentence), which it cannot"
            case .refused(let refusal):
                return "\"\(refusal.key.configText)\" cannot be its shortcut: \(refusal.reason)"
            }
        }
    }

    /// The entries of `listings` this record would not take, each with why:
    /// one naming a kind of window its action cannot work in (FR12's branch
    /// E), as Add Feed… cannot work in reader windows, and one giving its
    /// action keys it cannot take (`ShortcutListing.refusal(for:)`, FR12's
    /// branch D), unless the record holds those keys already, as a store
    /// edited by hand may, which then go on as they are.
    func entriesLeftOut(of listings: [ShortcutAction: ShortcutListing]) -> [ShortcutAction: LeftOutEntry] {
        listings.reduce(into: [:]) { leftOut, entry in
            let (action, listing) = entry
            if let scope = listing.scope(for: action), !action.availableScopes.contains(scope) {
                leftOut[action] = .cannotWorkIn(scope)
            } else if listing.bindings != keys(of: action), let refusal = listing.refusal(for: action) {
                leftOut[action] = .refused(refusal)
            }
        }
    }
}

// MARK: - In the Preferences Store

extension ShortcutEdits {
    /// The record as the preferences store keeps it: JSON keyed by the
    /// edited actions' names, each with its list of keys, the form the whole
    /// map was saved in before the record, or, for an action working in a
    /// scope the user chose, an object holding its keys and the scope
    /// (`StoredEntry`, FR12's branch E). Its entries are written in sorted
    /// order, so one record is always the same bytes, and saving it again
    /// changes nothing in the store. Nil only should encoding fail, which
    /// leaves the store as it was.
    var storedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var entries: [String: StoredEntry] = [:]
        for (action, keys) in keysByEditedAction {
            entries[action.rawValue] = StoredEntry(keys: keys, worksIn: scopesByEditedAction[action])
        }
        return try? encoder.encode(entries)
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
    /// An entry naming a scope this build does not know, or one its action
    /// may not be given, keeps its keys and works where its default scope
    /// does, which is reported too. Data that is not such an object at all
    /// reads as an empty record.
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
        var scopes: [ShortcutAction: ShortcutScope] = [:]
        var skipped: [SkippedEntry] = []
        // In the order of their names, so the entries left out are reported
        // in the same order every time.
        for (name, entry) in entries.sortedStably(by: { $0.key < $1.key }) {
            // A record written under an action's former name still names it.
            guard let action = ShortcutAction.exactlyNamed(name) else {
                skipped.append(SkippedEntry(name: name, reason: "names nothing TextMouth knows; leaving it out"))
                continue
            }
            guard let actionKeys = entry.keys else {
                skipped.append(SkippedEntry(name: name, reason: "could not be read as a list of shortcuts; leaving it out"))
                continue
            }
            keys[action] = actionKeys
            if let scopeName = entry.scopeName {
                guard let scope = ShortcutScope(rawValue: scopeName), action.availableScopes.contains(scope) else {
                    skipped.append(SkippedEntry(
                        name: name,
                        reason: "works in \"\(scopeName)\", which it cannot; working where it does by default"
                    ))
                    continue
                }
                scopes[action] = scope
            }
        }
        return StoredReading(edits: ShortcutEdits(keys, scopes: scopes), skipped: skipped)
    }
}

/// One edited action as the preferences store keeps it (FR12's branch E):
/// its list of keys, as every entry was before scopes, or, when it works in
/// a scope the user chose, an object holding its keys and that scope's name.
private struct StoredEntry: Encodable {
    /// The action's keys.
    let keys: [KeyBinding]
    /// The scope the user chose, or nil for the action's default.
    let worksIn: ShortcutScope?

    /// Writes a list of keys for the default scope, else an object.
    func encode(to encoder: Encoder) throws {
        guard let worksIn else {
            var container = encoder.singleValueContainer()
            try container.encode(keys)
            return
        }
        var container = encoder.container(keyedBy: ShortcutJSONKey.self)
        try container.encode(keys, forKey: .keys)
        try container.encode(worksIn.rawValue, forKey: .worksIn)
    }
}

/// One stored entry's keys, or nil when they cannot be read, so that one
/// entry never fails the others, and the name of the scope it works in,
/// when it names one.
private struct LenientStoredKeys: Decodable {
    /// The entry's keys, or nil.
    let keys: [KeyBinding]?
    /// The name of the scope an entry written as an object gives, or nil.
    let scopeName: String?

    /// Reads the entry's value as a list of keys, or as an object holding
    /// its keys and a scope's name; nil keys for anything else.
    init(from decoder: Decoder) throws {
        if let keys = try? decoder.singleValueContainer().decode([KeyBinding].self) {
            self.keys = keys
            scopeName = nil
            return
        }
        let object = try? decoder.container(keyedBy: ShortcutJSONKey.self)
        keys = try? object?.decode([KeyBinding].self, forKey: .keys)
        scopeName = try? object?.decode(String.self, forKey: .worksIn)
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
                codingPath: [ShortcutJSONKey(field)] + (entry.name.map { [ShortcutJSONKey($0)] } ?? []),
                detail: entry.reason
            )
        }
    }

    /// Writes one STORED_VALUE_REPAIRED line to the debug log for each key
    /// two edited actions held in `field` of `source`, naming the key, the
    /// action that keeps it, and the one that goes without it, such as
    /// "config.json keyboardShortcuts.Show Bookmarks: shared
    /// "shift+command+b" with "Next Bookmark", which keeps it; "Show
    /// Bookmarks" goes without it". A key clashing with a different key of
    /// the keeper's, a key equivalent's and its double press, names both:
    /// "…: "command+o" clashed with "Book Info"'s "command+o twice", which
    /// keeps it; "Open Book…" goes without it".
    static func log(_ sharedKeys: [SharedKey], source: String, field: String) {
        for shared in sharedKeys {
            let clash = shared.keepersKey.map { keepersKey in
                "\"\(shared.key.configText)\" clashed with \"\(shared.keeper.rawValue)\"'s \"\(keepersKey.configText)\""
            } ?? "shared \"\(shared.key.configText)\" with \"\(shared.keeper.rawValue)\""
            StoredValueRepair.log(
                source: source,
                codingPath: [ShortcutJSONKey(field), ShortcutJSONKey(shared.loser.rawValue)],
                detail: "\(clash), which keeps it; \"\(shared.loser.rawValue)\" goes without it"
            )
        }
    }
}

extension ShortcutEdits {
    /// Writes one STORED_VALUE_REPAIRED line to the debug log for each entry
    /// of `field` in `source` left out (`entriesLeftOut(of:)`, FR12's
    /// branches D and E), in the order Settings lists the actions, such as
    /// "config.json keyboardShortcuts.Open Book…: "w" cannot be its
    /// shortcut: a menu command's shortcut is one press of a key with
    /// Command or Control; keeping its shortcuts", or "config.json
    /// keyboardShortcuts.Add Feed…: works in reader windows, which it
    /// cannot; keeping its shortcuts".
    static func log(_ leftOut: [ShortcutAction: LeftOutEntry], source: String, field: String) {
        for action in ShortcutAction.allCases {
            guard let entry = leftOut[action] else { continue }
            StoredValueRepair.log(
                source: source,
                codingPath: [ShortcutJSONKey(field), ShortcutJSONKey(action.rawValue)],
                detail: "\(entry.reason); keeping its shortcuts"
            )
        }
    }
}

/// A key of a JSON object, named by text (FR12): a field of a shortcut
/// entry written as an object, "keys" or "worksIn", in the preferences store
/// or in config.json, or a field or an entry a repair log line names, the
/// parts of "keyboardShortcuts.Show Bookmarks".
struct ShortcutJSONKey: CodingKey, Equatable {
    /// The field of an entry written as an object holding its keys.
    static let keys = ShortcutJSONKey("keys")
    /// The field of an entry written as an object naming the kind of window
    /// its keys work in (FR12's branch E).
    static let worksIn = ShortcutJSONKey("worksIn")

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

    /// The name as config.json's field names are compared: in lower case,
    /// without spaces, so "Works In" is "worksIn".
    var comparableName: String {
        stringValue.lowercased().filter { !$0.isWhitespace }
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
