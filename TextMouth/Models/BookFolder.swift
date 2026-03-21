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
}
