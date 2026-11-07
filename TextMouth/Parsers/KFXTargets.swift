import Foundation

/// Where the book's navigation and links point into its text: node ids, each
/// with the offsets (in code points) the book names in it. The walk writes
/// an anchor at each, so contents entries, links, and pages land on their
/// words once the HTML is converted.
struct KFXTargets {
    /// The offsets named, by node id.
    private(set) var offsets: [Int: Set<Int>] = [:]
    /// The label of the page that begins at an offset of a node, by node id
    /// and offset: the first page the book's list gives that place.
    private(set) var pageLabels: [Int: [Int: String]] = [:]

    /// Names the place `offset` in node `node`. A negative offset names the
    /// node's start.
    mutating func add(node: Int, offset: Int) {
        offsets[node, default: []].insert(max(0, offset))
    }

    /// Names the place where page `label` begins.
    mutating func addPage(node: Int, offset: Int, label: String) {
        add(node: node, offset: offset)
        if pageLabels[node]?[max(0, offset)] == nil, !label.isEmpty {
            pageLabels[node, default: [:]][max(0, offset)] = label
        }
    }

    /// The id of the anchor written at `offset` in node `node`; the node's
    /// start has no offset in its id.
    static func anchorID(node: Int, offset: Int) -> String {
        offset == 0 ? "kfx-\(node)" : "kfx-\(node)-\(offset)"
    }

    /// The HTML of that anchor.
    static func anchorHTML(node: Int, offset: Int) -> String {
        "<a id=\"\(anchorID(node: node, offset: offset))\"></a>"
    }
}
