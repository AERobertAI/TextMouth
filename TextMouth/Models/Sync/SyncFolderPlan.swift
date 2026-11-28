import Foundation

/// The folders of a library once the merged state is applied (FR43, section 5
/// of the plan): which folders live, where each sits, and what becomes of
/// the books and folders of one that does not. Pure, and the same on every
/// device for the same registers.
///
/// The rules, in order:
/// 1. A folder is removed when its removal mark is later than all its other
///    entries (its name and parent), so a later change brings it back.
/// 2. A removed parent's children go to its nearest live ancestor.
/// 3. A cycle of parents is cut at its latest parent change, to the top.
/// 4. A folder deeper than `BookFolder.maxDepth` rises to it.
/// 5. Two live folders of one name under one parent fold into the older, and
///    the plan records the moves and the removal.
struct SyncFolderPlan {
    /// A folder, as the plan builds it.
    private struct Node {
        var id: UUID
        var name: String
        /// The parent as an entry or the library says, live or not.
        var parent: UUID?
        /// The stamp of the parent entry, to cut a cycle at its latest change.
        var parentStamp: SyncStamp?
        /// When the folder was made: its presence stamp, or its creation date.
        var created: SyncStamp
        var isLive: Bool
        /// The folder this one was folded into, when its removal mark says so.
        var foldedInto: UUID?
        var existing: BookFolder?
        /// Whether its removal mark stands: a folder a person removed (or folded), not one
        /// whose entries are still arriving.
        var isRemoved = false
    }

    /// The live folders after every rule, in the library's order and then new ones by age.
    private(set) var folders: [BookFolder] = []
    /// The full path of each live folder.
    private(set) var pathByID: [UUID: String] = [:]
    /// The folder each folded folder became.
    private(set) var redirect: [UUID: UUID] = [:]
    /// What to record so that every device reaches the same state: folded folders removed, their folders and books moved.
    private(set) var entriesToRecord: [SyncKey: JSONValue] = [:]
    /// Every folder key the plan used.
    private(set) var appliedKeys: Set<SyncKey> = []
    /// Whether the folders differ from the library's (a folder added, removed, renamed, or moved).
    private(set) var changesFolders = false
    /// Old full paths that are now other paths, for the folders' sort settings.
    private(set) var renamedPaths: [String: String] = [:]
    /// Full paths of folders that are gone.
    private(set) var removedPaths: Set<String> = []

    private var nodes: [UUID: Node] = [:]
    /// The live folders' parents after rules 2 to 5.
    private var parentOf: [UUID: UUID?] = [:]

    /// Makes the plan for `library` and the winners `entries`.
    init(library: Library, entries: [SyncKey: SyncEntry]) {
        let index = SyncFolderIndex(library.folders)
        collectNodes(library: library, index: index, entries: entries)
        for id in sortedLiveIDs() { parentOf[id] = nearestLiveAncestor(of: id) }
        cutCycles()
        raiseDeepFolders()
        foldDuplicates()
        build(library: library)
    }

    /// The folder a book (or folder) of folder `id` goes to: `id` while it
    /// lives, the folder it was folded into, else the nearest live ancestor;
    /// nil for the top level.
    func landing(_ id: UUID?) -> UUID? {
        guard var current = id else { return nil }
        var seen = Set<UUID>()
        while seen.insert(current).inserted {
            if pathByID[current] != nil { return current }
            if let folded = redirect[current] ?? nodes[current]?.foldedInto { current = folded; continue }
            guard let parent = nodes[current]?.parent else { return nil }
            current = parent
        }
        return nil
    }

    /// The folder a feed listing in folder `id` lists in once the plan is applied (FR56): `id`
    /// while it lives, the live folder it was folded into, and, for a folder removed without a
    /// fold, the removed folder itself, so the feed stays without a folder, as Delete Folder…
    /// leaves one on its own device, rather than taking over a folder above it that holds a
    /// person's books. Nil for a folder whose entries haven't all arrived, which the feed waits for.
    func feedFolder(_ id: UUID) -> UUID? {
        var current = id
        var seen = Set<UUID>()
        while seen.insert(current).inserted {
            if pathByID[current] != nil { return current }
            guard let node = nodes[current], node.isRemoved else { return nil }
            guard let folded = redirect[current] ?? node.foldedInto else { return current }
            current = folded
        }
        // A loop of folds lands nowhere.
        return nil
    }

    /// Whether `id` is a folder the plan knows, live or not.
    func knows(_ id: UUID) -> Bool { nodes[id] != nil }

    /// The full path of the folder `id` lands in, "" for the top level.
    func path(landingOf id: UUID?) -> String {
        landing(id).flatMap { pathByID[$0] } ?? ""
    }

    // MARK: - Building the nodes

    /// Reads every folder of the library and every folder the entries name.
    private mutating func collectNodes(library: Library, index: SyncFolderIndex, entries: [SyncKey: SyncEntry]) {
        for folder in library.folders {
            nodes[folder.id] = Node(
                id: folder.id, name: folder.name, parent: index.id(atPath: folder.parentPath), parentStamp: nil,
                created: SyncStamp(wall: SyncClock.milliseconds(of: folder.dateCreated), counter: 0, device: ""),
                isLive: true, foldedInto: nil, existing: folder
            )
        }
        var registered = Set<UUID>()
        for key in entries.keys { if let id = key.folderID { registered.insert(id) } }
        for id in registered {
            let presence = entries[.folder(id, .presence)]
            let name = entries[.folder(id, .name)]
            let parent = entries[.folder(id, .parent)]
            var node = nodes[id] ?? Node(
                id: id, name: "", parent: nil, parentStamp: nil,
                created: presence?.stamp ?? SyncStamp(wall: 0, counter: 0, device: ""), isLive: false, foldedInto: nil, existing: nil
            )
            if let presence { node.created = presence.stamp }
            // A name from another device passes through the rules a name made here does, so that a
            // "/" or ".." in a damaged file cannot split a path or make the apply refuse.
            if let text = name?.value.stringValue, let normalized = BookFolder.normalizedName(text) { node.name = normalized }
            if let parent {
                node.parent = SyncValueCoding.uuid(from: parent.value)
                node.parentStamp = parent.stamp
            }
            if let presence {
                // Removed only if nothing else about the folder is later than the removal mark.
                let newest = [name?.stamp, parent?.stamp].compactMap { $0 }.max()
                node.isLive = !presence.key.marksRemoval(presence.value) || (newest.map { $0 > presence.stamp } ?? false)
                node.foldedInto = node.isLive ? nil : SyncValueCoding.uuid(from: presence.value)
                node.isRemoved = !node.isLive
            } else {
                node.isLive = node.existing != nil
            }
            // A folder that no entry names and the library lacks has no name to show: it is not made.
            if node.existing == nil, node.name.isEmpty { node.isLive = false }
            nodes[id] = node
            appliedKeys.formUnion([.folder(id, .presence), .folder(id, .name), .folder(id, .parent)].filter { entries[$0] != nil })
        }
    }

    /// The IDs of the live folders in a fixed order.
    private func sortedLiveIDs() -> [UUID] {
        nodes.values.filter(\.isLive).map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    /// The nearest live ancestor of `id`: its parent if that lives, else the
    /// parent's, and so on; nil for the top level and for a chain that loops.
    private func nearestLiveAncestor(of id: UUID) -> UUID? {
        var seen: Set<UUID> = [id]
        var next = nodes[id]?.parent
        while let candidate = next {
            if nodes[candidate]?.isLive == true { return candidate }
            guard seen.insert(candidate).inserted else { return nil }
            // A folder folded into another is its place's, whatever its own parent was.
            next = nodes[candidate]?.foldedInto ?? nodes[candidate]?.parent
        }
        return nil
    }

    // MARK: - The rules

    /// Rule 3: cuts each cycle of parents at its latest parent change, to the top.
    private mutating func cutCycles() {
        var cut = true
        while cut {
            cut = false
            for start in sortedLiveIDs() {
                var walk: [UUID] = []
                var current: UUID? = start
                while let id = current, !walk.contains(id) {
                    walk.append(id)
                    current = parentOf[id] ?? nil
                }
                guard let repeated = current, let first = walk.firstIndex(of: repeated) else { continue }
                // The folders of the cycle, and the one whose parent changed last.
                let members = Array(walk[first...])
                let latest = members.max { left, right in
                    let a = nodes[left]?.parentStamp ?? SyncStamp(wall: -1, counter: 0, device: "")
                    let b = nodes[right]?.parentStamp ?? SyncStamp(wall: -1, counter: 0, device: "")
                    return (a, left.uuidString) < (b, right.uuidString)
                }
                if let latest { parentOf[latest] = .some(nil) }
                cut = true
                break
            }
        }
    }

    /// The depth of a live folder: 1 for one at the top.
    private func depth(of id: UUID) -> Int {
        var depth = 1
        var current = parentOf[id] ?? nil
        while let parent = current {
            depth += 1
            current = parentOf[parent] ?? nil
        }
        return depth
    }

    /// Rule 4: a folder deeper than the limit takes the ancestor at one above the limit as its parent.
    private mutating func raiseDeepFolders() {
        while true {
            let deep = sortedLiveIDs().map { ($0, depth(of: $0)) }.filter { $0.1 > BookFolder.maxDepth }
            guard let shallowest = deep.min(by: { ($0.1, $0.0.uuidString) < ($1.1, $1.0.uuidString) }) else { return }
            var ancestor: UUID? = shallowest.0
            for _ in 0..<(shallowest.1 - (BookFolder.maxDepth - 1)) { ancestor = parentOf[ancestor!] ?? nil }
            parentOf[shallowest.0] = .some(ancestor)
        }
    }

    /// A name as folders compare it: the same text in any case and any Unicode form.
    private static func foldedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Rule 5: folds same-named folders under one parent into the oldest, again until none are left.
    private mutating func foldDuplicates() {
        while true {
            var groups: [String: [UUID]] = [:]
            for id in sortedLiveIDs() {
                let parent = (parentOf[id] ?? nil)?.uuidString ?? ""
                groups[parent + "/" + Self.foldedName(nodes[id]?.name ?? ""), default: []].append(id)
            }
            guard let group = groups.keys.sorted().compactMap({ groups[$0] }).first(where: { $0.count > 1 }) else { return }
            // The oldest keeps the name; the others go into it.
            let ordered = group.sorted { left, right in
                let a = nodes[left]?.created ?? SyncStamp(wall: 0, counter: 0, device: "")
                let b = nodes[right]?.created ?? SyncStamp(wall: 0, counter: 0, device: "")
                return (a, left.uuidString) < (b, right.uuidString)
            }
            let keeper = ordered[0]
            for folded in ordered.dropFirst() {
                redirect[folded] = keeper
                nodes[folded]?.isLive = false
                nodes[folded]?.isRemoved = true
                parentOf[folded] = nil
                // The removal mark names the folder it folded into, so that it lasts: a book recorded
                // into this folder later still lands in the survivor, and so does a folder.
                entriesToRecord[.folder(folded, .presence)] = SyncValueCoding.id(keeper)
                nodes[folded]?.foldedInto = keeper
                for child in sortedLiveIDs() where (parentOf[child] ?? nil) == folded {
                    parentOf[child] = .some(keeper)
                }
            }
        }
    }

    // MARK: - The result

    /// Works out the paths and the folders of the library from the rules' result.
    private mutating func build(library: Library) {
        for id in sortedLiveIDs() { pathByID[id] = fullPath(of: id) }

        var result: [BookFolder] = []
        for old in library.folders {
            guard let path = pathByID[old.id], let node = nodes[old.id] else {
                removedPaths.insert(old.fullPath)
                changesFolders = true
                continue
            }
            var folder = old
            folder.name = node.name
            folder.parentPath = Self.parentPath(of: path)
            if folder != old {
                changesFolders = true
                if folder.fullPath != old.fullPath { renamedPaths[old.fullPath] = folder.fullPath }
            }
            result.append(folder)
        }
        // Folders another device made, oldest first.
        let known = Set(library.folders.map(\.id))
        let added = sortedLiveIDs().filter { !known.contains($0) }.sorted { left, right in
            let a = nodes[left]!.created, b = nodes[right]!.created
            return (a, left.uuidString) < (b, right.uuidString)
        }
        for id in added {
            guard let path = pathByID[id], let node = nodes[id] else { continue }
            result.append(BookFolder(
                id: id, name: node.name, parentPath: Self.parentPath(of: path),
                dateCreated: Date(timeIntervalSince1970: Double(node.created.wall) / 1000)
            ))
            changesFolders = true
        }
        folders = result
    }

    /// The full path of a live folder: its ancestors' names and its own, joined by "/".
    private func fullPath(of id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        while let folder = current {
            names.append(nodes[folder]?.name ?? "")
            current = parentOf[folder] ?? nil
        }
        return names.reversed().joined(separator: "/")
    }

    /// The path above `path`: everything before its last "/", or "" at the top.
    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
