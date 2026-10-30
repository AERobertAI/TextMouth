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

    /// The most entries read from config.json, which is untrusted.
    static let entryLimit = 200
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
    /// `entryLimit` entries, each read on its own, and kept as it was when
    /// it cannot be read. An empty list reads as the shipped one. With a
    /// `source`, every repair is logged as that file's.
    init(fileEntries: [JSONValue], logRepairsAs source: String? = nil) {
        let reading = LibraryViewEntryReading(source: source, path: [LibraryViewFileKey(Self.fileKey)])
        if fileEntries.count > Self.entryLimit {
            reading.logRepair(of: nil, "kept the first \(Self.entryLimit) of \(fileEntries.count) views")
        }
        let read = fileEntries.prefix(Self.entryLimit).enumerated().map { index, value -> Entry in
            guard let view = LibraryViewDefinition(fileEntry: value, reading: reading.element(index)) else {
                return .unreadable(value)
            }
            return .view(view)
        }
        self.init(entries: read)
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
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return views.contains { view in
            view.id != id && view.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
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
        entries[index] = .view(view)
        return true
    }

    /// Adds `view` just after the view `id`, or at the end when `id` is nil
    /// or not in the list. Returns false, adding nothing, when the list has
    /// a view with its identity already.
    @discardableResult
    mutating func add(_ view: LibraryViewDefinition, after id: LibraryViewID?) -> Bool {
        guard self.view(view.id) == nil else { return false }
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
    /// custom view, a view not in the list, or one already as shipped. Its
    /// sort, which library.json keeps, is the caller's to remove.
    @discardableResult
    mutating func restoreDefault(_ id: LibraryViewID) -> Bool {
        guard let shipped = LibraryViewDefinition.shipped(id),
              shipped.kind == .filter,
              let index = entryIndex(of: id),
              case .view(var view) = entries[index],
              view.differsFromShipped else {
            return false
        }
        view.name = shipped.name
        view.filter = shipped.filter
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
