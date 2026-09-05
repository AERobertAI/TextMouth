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
    static func normalizedName(_ name: String) -> String? {
        let normalized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func isValidLibraryPath(_ path: String) -> Bool {
        path.isEmpty || path.components(separatedBy: "/").allSatisfy {
            normalizedName($0) == $0
        }
    }
}
