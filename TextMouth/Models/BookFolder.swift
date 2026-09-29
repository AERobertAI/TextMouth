import Foundation

struct BookFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentPath: String  // empty for root-level folders
    var dateCreated: Date

    init(id: UUID = UUID(), name: String, parentPath: String = "", dateCreated: Date = Date()) {
        self.id = id
        self.name = name
        self.parentPath = parentPath
        self.dateCreated = dateCreated
    }

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
              !["__allItems__", "__noFolder__", "__recent__"].contains(normalized) else {
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
