import Foundation

/// The Library's views in their order (design section 2): the views this
/// TextMouth can read, and, in their places, the entries it cannot, such as
/// a view a later TextMouth added, kept to be written back exactly as they
/// were and never offered.
///
/// The list always holds every built-in view: one missing from what was read
/// is added at the end with the view TextMouth ships, so no hand edit can
/// lose one, and a built-in view a later TextMouth adds appears. Folders is
/// always offered. Every operation keeps these rules, and each says whether
/// it changed anything, for the words VoiceOver says after it.
struct LibraryViewDefinitionList: Equatable, Sendable {
    /// One entry of the list.
    enum Entry: Equatable, Sendable {
        /// A view this TextMouth reads.
        case view(LibraryViewDefinition)
        /// An entry it cannot read, kept as config.json held it.
        case unreadable(JSONValue)
    }

    /// The entries, in order.
    private(set) var entries: [Entry]

    /// The most views the list holds: `add` refuses a view past it, and
    /// New View… and Duplicate are dimmed there (review of October 31, 2026,
    /// finding 1).
    static let entryLimit = 200
    /// The most entries read from config.json, which is untrusted: the
    /// limit, and room for the built-in views the list adds at its end, so
    /// every list this TextMouth writes reads back whole.
    static let readLimit = entryLimit + LibraryViewID.builtIns.count
    /// The key the list is kept under in config.json and the preferences
    /// store.
    static let fileKey = "libraryViews"

    /// The list TextMouth ships: Folders, All Items, Unopened, Recently
    /// Opened, and the Reading List, always offered, then Feeds, offered
    /// when applicable.
    static let shipped = LibraryViewDefinitionList(
        entries: LibraryViewID.builtIns.compactMap { LibraryViewDefinition.shipped($0) }.map(Entry.view)
    )

    /// A list of `entries`, kept to the list's rules: a view whose identity
    /// an earlier view has is kept as an unreadable entry, Folders is always
    /// offered, Folders and the Reading List keep their own names and have
    /// no filter, a custom view without a filter is kept as unreadable, and
    /// every built-in view missing is added at the end.
    init(entries: [Entry]) {
        self.entries = Self.normalized(entries)
    }

    /// Reads the list config.json or the preferences store holds: at most
    /// `readLimit` entries, each read on its own, and kept as it was when
    /// it cannot be read. An empty list reads as the shipped one. A second
    /// entry of a built-in view that holds nothing but its identity and
    /// visibility, as TextMouth adds one, is dropped; a view whose name
    /// another view has is shown numbered apart ("Feeds 2") and written back
    /// as read (`numberNamesApart`; review of October 31, 2026, findings 3
    /// and 5). With a `source`, every repair is logged as that file's.
    init(fileEntries: [JSONValue], logRepairsAs source: String? = nil) {
        let reading = LibraryViewEntryReading(source: source, path: [LibraryViewFileKey(Self.fileKey)])
        if fileEntries.count > Self.readLimit {
            reading.logRepair(of: nil, "kept the first \(Self.readLimit) of \(fileEntries.count) views")
        }
        var read: [Entry] = []
        // Where in the file each entry of `read` was, for the log.
        var places: [LibraryViewEntryReading] = []
        var seenIDs = Set<LibraryViewID>()
        for (index, value) in fileEntries.prefix(Self.readLimit).enumerated() {
            let place = reading.element(index)
            guard let view = LibraryViewDefinition(fileEntry: value, reading: place) else {
                read.append(.unreadable(value))
                places.append(place)
                continue
            }
            if !seenIDs.insert(view.id).inserted, view.isBuiltIn, Self.holdsOnlyIdentityAndVisibility(value) {
                // A plain copy of a built-in view already listed adds nothing.
                place.logRepair(of: nil, "dropped a second plain entry of a built-in view")
                continue
            }
            read.append(.view(view))
            places.append(place)
        }
        self.init(entries: read)
        // After the built-in views missing were added, so their names count.
        numberNamesApart(places: places, list: reading)
    }

    /// Whether `entry` holds nothing but an identity and a visibility.
    private static func holdsOnlyIdentityAndVisibility(_ entry: JSONValue) -> Bool {
        guard case .object(let members) = entry else { return false }
        return Set(members.keys) == ["id", "visibility"]
    }

    /// Shows each filter view whose name an earlier view has, or Folders or
    /// the Reading List, whose names never change, numbered apart: "Feeds
    /// 2", or the first number no view's name has. Its entry keeps the name
    /// it was read with (`keptAsRead`), so config.json is written back as it
    /// was until the listener renames the view (review of October 31, 2026,
    /// finding 5). `places` says where each of the first entries was in the
    /// file, for the log; the built-in views added after them, under `list`,
    /// were in none.
    private mutating func numberNamesApart(places: [LibraryViewEntryReading], list: LibraryViewEntryReading) {
        // Every name in the list, so a number never takes a later view's.
        let everyName = views.map(\.name)
        var taken = views.filter { $0.kind != .filter }.map(\.name)
        for index in entries.indices {
            guard case .view(var view) = entries[index], view.kind == .filter else { continue }
            if Self.isName(view.name, among: taken) {
                if !view.keptAsRead.keys.contains("name") {
                    // The name as written now: as read, or none at all for a
                    // built-in view's own.
                    view.keptAsRead.updateValue(view.fileEntry["name"], forKey: "name")
                }
                view.name = Self.numberedName(for: view.name, among: taken + everyName)
                entries[index] = .view(view)
                if places.indices.contains(index) {
                    places[index].logRepair(of: "name", "numbered a name another view has")
                } else {
                    list.logRepair(of: nil, "numbered the name of a built-in view added at the end")
                }
            }
            taken.append(view.name)
        }
    }

    /// Whether `name` is among `names`, compared as `isNameTaken` compares.
    private static func isName(_ name: String, among names: [String]) -> Bool {
        names.contains { sameName($0, name) }
    }

    /// Whether two names are one to a listener: the same once trimmed,
    /// without regard to case or diacritics.
    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(rhs.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }

    /// `name` numbered apart from `names`: "Feeds 2", "Feeds 3", and on,
    /// the name cut first where the number would pass the limit.
    private static func numberedName(for name: String, among names: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        // One more number than there are names always finds a free one.
        for number in 2...(names.count + 2) {
            let suffix = " \(number)"
            let room = max(LibraryViewDefinition.nameLimit - suffix.count, 0)
            candidate = String(base.prefix(room)).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            if !isName(candidate, among: names) {
                break
            }
        }
        return candidate
    }

    /// The list as config.json holds it: each view's entry, and each entry
    /// this TextMouth cannot read as it was.
    var fileEntries: [JSONValue] {
        entries.map { entry in
            switch entry {
            case .view(let view): return view.fileEntry
            case .unreadable(let value): return value
            }
        }
    }

    // MARK: - Reading the List

    /// The views this TextMouth reads, in order.
    var views: [LibraryViewDefinition] {
        entries.compactMap { entry in
            guard case .view(let view) = entry else { return nil }
            return view
        }
    }

    /// How many entries need a later TextMouth.
    var unreadableCount: Int {
        entries.reduce(0) { count, entry in
            guard case .unreadable = entry else { return count }
            return count + 1
        }
    }

    /// The view with identity `id`, if the list has it.
    func view(_ id: LibraryViewID) -> LibraryViewDefinition? {
        views.first { $0.id == id }
    }

    /// The place of the view `id` among the views, counted from 1, and how
    /// many views there are, as "Reading List, 4 of 6" says it; nil when the
    /// list does not have it.
    func place(of id: LibraryViewID) -> (number: Int, count: Int)? {
        let views = self.views
        guard let index = views.firstIndex(where: { $0.id == id }) else { return nil }
        return (index + 1, views.count)
    }

    /// The views a Library window's View pop-up offers, in the list's
    /// order: those offered always, those offered when applicable while
    /// `isApplicable` says they list something, and `current`, the view the
    /// window shows, whatever its visibility, so a window never loses the
    /// view it shows (design section 5).
    func offeredViews(current: LibraryViewID?, isApplicable: (LibraryViewDefinition) -> Bool) -> [LibraryViewDefinition] {
        views.filter { view in
            view.id == current
                || view.visibility == .always
                || (view.visibility == .whenApplicable && isApplicable(view))
        }
    }

    /// The first view the View pop-up offers a window that shows none yet:
    /// where a new Library window opens, and where one goes when its view is
    /// deleted. Folders, which is always offered, when nothing is before it.
    func firstOffered(isApplicable: (LibraryViewDefinition) -> Bool) -> LibraryViewDefinition {
        offeredViews(current: nil, isApplicable: isApplicable).first
            ?? view(.category(.folders))
            ?? LibraryViewDefinition.shipped(.folders)
    }

    /// Whether a view other than `except` is named `name`, comparing the
    /// names trimmed, without regard to case or diacritics, as a listener
    /// telling two views apart by ear would.
    func isNameTaken(_ name: String, except id: LibraryViewID?) -> Bool {
        views.contains { $0.id != id && Self.sameName($0.name, name) }
    }

    /// Whether the list has room for another view (`entryLimit`).
    var canAdd: Bool {
        entries.count < Self.entryLimit
    }

    /// The name Duplicate gives a copy of the view named `name`: "Unopened
    /// Copy", or "Unopened Copy 2", "Unopened Copy 3", and on, the first no
    /// view has, the name cut first where the suffix would pass the limit.
    func copyName(for name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        // One more number than there are views always finds a free name.
        for number in 1...(views.count + 1) {
            let suffix = number == 1 ? " Copy" : " Copy \(number)"
            let room = max(LibraryViewDefinition.nameLimit - suffix.count, 0)
            candidate = String(base.prefix(room)).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            if !isNameTaken(candidate, except: nil) {
                break
            }
        }
        return candidate
    }

    // MARK: - Changing the List

    /// Moves the view `id` one place up (-1) or down (+1) among the views,
    /// trading places with its neighbour; entries this TextMouth cannot read
    /// stay where they are. Returns false, changing nothing, at the end it
    /// cannot pass, for a view not in the list, or for any other offset.
    @discardableResult
    mutating func move(_ id: LibraryViewID, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        let views = self.views
        guard let position = views.firstIndex(where: { $0.id == id }),
              views.indices.contains(position + offset),
              let from = entryIndex(of: id),
              let neighbour = entryIndex(of: views[position + offset].id) else {
            return false
        }
        let entry = entries.remove(at: from)
        // Removing the view shifts a neighbour after it one place up.
        let neighbourNow = neighbour > from ? neighbour - 1 : neighbour
        entries.insert(entry, at: offset < 0 ? neighbourNow : neighbourNow + 1)
        return true
    }

    /// Sets when the View pop-up offers the view `id`. Returns false,
    /// changing nothing, for Folders, which is always offered, for a view
    /// not in the list, or when it is offered so already.
    @discardableResult
    mutating func setVisibility(_ visibility: LibraryViewVisibility, of id: LibraryViewID) -> Bool {
        guard id != .category(.folders),
              let index = entryIndex(of: id),
              case .view(var view) = entries[index],
              view.visibility != visibility else {
            return false
        }
        view.visibility = visibility
        view.forgetReadValue(of: "visibility")
        entries[index] = .view(view)
        return true
    }

    /// Adds `view` just after the view `id`, or at the end when `id` is nil
    /// or not in the list. Returns false, adding nothing, when the list has
    /// a view with its identity already, or no room (`canAdd`).
    @discardableResult
    mutating func add(_ view: LibraryViewDefinition, after id: LibraryViewID?) -> Bool {
        guard canAdd, self.view(view.id) == nil else { return false }
        let index = id.flatMap { entryIndex(of: $0) }.map { $0 + 1 } ?? entries.count
        entries.insert(.view(view), at: index)
        entries = Self.normalized(entries)
        return true
    }

    /// Puts `view` in the place of the view with its identity. Folders and
    /// the Reading List keep their own names and no filter, Folders stays
    /// always offered, and a filter view needs a filter. Returns false,
    /// changing nothing, when the list has no such view, when `view` would
    /// change nothing, or when a filter view would have no filter.
    @discardableResult
    mutating func replace(_ view: LibraryViewDefinition) -> Bool {
        guard let index = entryIndex(of: view.id), case .view(let old) = entries[index] else { return false }
        var new = view
        if new.kind != .filter {
            new.name = old.name
            new.filter = nil
        } else if new.filter == nil {
            return false
        }
        if new.id == .category(.folders) {
            new.visibility = .always
        }
        // What the entry was read with stays the stored view's, whatever
        // copy the caller holds; a member the listener changed is written as
        // it is now.
        new.extraFields = old.extraFields
        new.keptAsRead = old.keptAsRead
        if new.name != old.name { new.forgetReadValue(of: "name") }
        if new.visibility != old.visibility { new.forgetReadValue(of: "visibility") }
        if new.filter != old.filter { new.forgetReadValue(of: "filter") }
        guard new != old else { return false }
        entries[index] = .view(new)
        return true
    }

    /// Deletes the custom view `id`. Returns false, changing nothing, for a
    /// built-in view, which can be hidden but never deleted, or a view not
    /// in the list.
    @discardableResult
    mutating func delete(_ id: LibraryViewID) -> Bool {
        guard !id.isBuiltIn, let index = entryIndex(of: id) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Gives the built-in filter view `id` back its shipped name and filter,
    /// keeping its place, its visibility, and the keys it was read with.
    /// Returns false, changing nothing, for Folders, the Reading List, a
    /// custom view, a view not in the list, one already as shipped, or one
    /// whose shipped name another view has, which would make two views of
    /// one name (review of October 31, 2026, finding 5). Its sort, which
    /// library.json keeps, is the caller's.
    @discardableResult
    mutating func restoreDefault(_ id: LibraryViewID) -> Bool {
        guard let shipped = LibraryViewDefinition.shipped(id),
              shipped.kind == .filter,
              !isNameTaken(shipped.name, except: id),
              let index = entryIndex(of: id),
              case .view(var view) = entries[index],
              view.differsFromShipped else {
            return false
        }
        view.name = shipped.name
        view.filter = shipped.filter
        view.forgetReadValue(of: "name")
        view.forgetReadValue(of: "filter")
        entries[index] = .view(view)
        return true
    }

    // MARK: - The Rules

    /// The index among the entries of the view `id`.
    private func entryIndex(of id: LibraryViewID) -> Int? {
        entries.firstIndex { entry in
            guard case .view(let view) = entry else { return false }
            return view.id == id
        }
    }

    /// `entries` kept to the list's rules (see `init(entries:)`).
    private static func normalized(_ entries: [Entry]) -> [Entry] {
        var seen = Set<LibraryViewID>()
        var result: [Entry] = []
        result.reserveCapacity(entries.count + LibraryViewID.builtIns.count)
        for entry in entries {
            guard case .view(var view) = entry else {
                // An unreadable entry's identity never counts: it is not offered.
                result.append(entry)
                continue
            }
            guard seen.insert(view.id).inserted else {
                // A second view with one identity is kept, never offered.
                result.append(.unreadable(view.fileEntry))
                continue
            }
            if let shipped = LibraryViewDefinition.shipped(view.id), shipped.kind != .filter {
                view.name = shipped.name
                view.filter = nil
            } else if view.filter == nil {
                if let shipped = LibraryViewDefinition.shipped(view.id) {
                    view.filter = shipped.filter
                } else {
                    // A custom view without a filter lists nothing that can be known.
                    result.append(.unreadable(view.fileEntry))
                    continue
                }
            }
            if view.id == .category(.folders) {
                view.visibility = .always
            }
            result.append(.view(view))
        }
        for id in LibraryViewID.builtIns where !seen.contains(id) {
            if let shipped = LibraryViewDefinition.shipped(id) {
                result.append(.view(shipped))
            }
        }
        return result
    }
}
