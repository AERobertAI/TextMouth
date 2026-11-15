import Foundation

struct BookFolder: Identifiable, Codable, Hashable, KeepsUnknownKeysBesideSynthesizedCoding {
    let id: UUID
    var name: String
    var parentPath: String  // empty for root-level folders
    var dateCreated: Date
    /// How listening goes on from one book of the folder to another (FR19),
    /// for the books directly in it. Nil is the standard options, which are
    /// never stored, so a library written before it existed reads as
    /// standard and a folder left as it was saves exactly as it was. It
    /// follows the folder when the folder is renamed or moved, which change
    /// `name` and `parentPath` in place.
    var listeningOptions: ListeningOptions?

    init(id: UUID = UUID(), name: String, parentPath: String = "", dateCreated: Date = Date()) {
        self.id = id
        self.name = name
        self.parentPath = parentPath
        self.dateCreated = dateCreated
        self.listeningOptions = nil
    }

    /// The keys of the folder's entry in library.json that this TextMouth
    /// does not know (V04, `UnknownKeys`), written back as they were; none
    /// in a folder made here. A folder renamed or moved is changed in
    /// place, and keeps them. The synthesized coding passes them over:
    /// `Library` reads and writes them beside the fields
    /// (`WithUnknownKeys`).
    var unknownKeys = UnknownKeys()

    /// Whether `name` is a key of a folder's entry that this version knows
    /// (`KeepsUnknownKeysBesideSynthesizedCoding`).
    static func isCodingKey(_ name: String) -> Bool {
        CodingKeys(stringValue: name) != nil
    }

    /// What a folder's entry holds, for the scan that says whether a file
    /// can hold unknown keys (`StoredKeyScan`). Its listening options keep
    /// none, and are not looked into.
    static let keySchema = StoredKeySchema(isKnown: { BookFolder.isStoredKey($0) })

    var fullPath: String {
        if parentPath.isEmpty {
            return name
        }
        return "\(parentPath)/\(name)"
    }

    var depth: Int {
        if fullPath.isEmpty { return 0 }
        return fullPath.components(separatedBy: "/").count
    }

    static let maxDepth = 4

    /// The names no folder may have: the keys the categories' sort settings
    /// are saved under (`LibraryCategory.sortSettingsKey`), and the former No
    /// Folder category's key, which Unopened still reads.
    static let reservedNames: Set<String> = Set(LibraryCategory.allCases.compactMap(\.sortSettingsKey))
        .union([LibraryCategory.formerNoFolderSortSettingsKey])

    /// Normalize user-entered names without allowing filesystem navigation or
    /// names reserved for packages and the library's category sort settings.
    /// Names are stored in Unicode NFC, so a composed é (U+00E9) and a
    /// decomposed e + U+0301 persist identically; the user's casing is kept.
    static func normalizedName(_ name: String) -> String? {
        let normalized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized != ".", normalized != "..",
              !normalized.contains("\0"),
              !normalized.lowercased().hasSuffix(".tmb"),
              !Self.reservedNames.contains(normalized) else {
            return nil
        }
        return normalized
    }

    /// Internal paths are relative folder components, never absolute paths or
    /// paths containing traversal. The empty path denotes the library root.
    /// Swift's `==` treats canonically equivalent strings as equal, so names
    /// stored in decomposed form before names were kept in NFC stay valid.
    static func isValidLibraryPath(_ path: String) -> Bool {
        path.isEmpty || path.components(separatedBy: "/").allSatisfy {
            normalizedName($0) == $0
        }
    }

    /// Whether two names or paths use exactly the same Unicode scalars.
    /// Swift's `==` treats canonically equivalent strings as equal, which
    /// hides a normalization-only change such as a decomposed é becoming
    /// composed; renames and repairs need this exact comparison to see it.
    static func spellingsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}
