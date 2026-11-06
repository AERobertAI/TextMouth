import Foundation

/// A KFX book's navigation: its table of contents, its print page list, and
/// the heading levels its headings container gives (KFX-FORMAT-NOTES-2026-11-05.md,
/// parts 8 and 9). Each entry points at a position, a node and an offset in
/// code points, which the walk turns into an anchor in the HTML.
///
/// The book's own marks come first. A page list named `APPROXIMATE_PAGE_LIST`
/// was made by a machine and is not the print pages, so it is left out.
struct KFXNavigation {

    /// One entry: what it says and where it points.
    struct Entry: Equatable {
        var label: String
        var node: Int
        var offset: Int
        /// How deep the entry stands in its list: 1 for a top-level entry.
        var depth: Int
    }

    /// The table of contents, in the book's order, nested entries after their parent.
    private(set) var contents: [Entry] = []
    /// The print page list, in the book's order.
    private(set) var pages: [Entry] = []
    /// The heading level (1 to 6) the headings container gives a node, by id.
    private(set) var headingLevels: [Int: Int] = [:]
    /// Every position a link in the book points at (the anchors' positions).
    private(set) var linkTargets: [(node: Int, offset: Int)] = []

    // MARK: Symbols

    private static let containerTypeField = 235
    private static let containerNameField = 239
    private static let containerUnitsField = 247
    private static let readingOrderNameField = 178
    private static let containersField = 392
    private static let unitTypeField = 238
    private static let unitRepresentationField = 241
    private static let unitLabelField = 244
    private static let unitPositionField = 246
    private static let tableOfContentsType = 212
    private static let pageListType = 237
    private static let headingsType = 798
    /// The first of the six heading units, `$799` to `$804`, for levels 1 to 6.
    private static let firstHeadingLevelUnit = 799
    private static let approximatePageList = "APPROXIMATE_PAGE_LIST"

    /// The most units read in all, so a list that claims millions is cut.
    static let maximumUnits = 200_000

    // MARK: Reading

    /// Reads the navigation of the book whose fragments are `fragments`.
    init(_ fragments: KFXFragments) {
        readUnits(of: fragments)
        for anchor in fragments.all(KFXSymbol.anchor).values {
            guard let position = anchor.structValue?[KFXSymbol.anchorPosition]?.structValue,
                  let node = position[KFXSymbol.positionNode]?.intValue else { continue }
            linkTargets.append((node, position[KFXSymbol.positionOffset]?.intValue ?? 0))
        }
    }

    /// One unit waiting to be read, with its depth and, for the headings
    /// container, the level it inherits.
    private struct Pending {
        var unit: IonValue
        var depth: Int
        var level: Int?
    }

    private mutating func readUnits(of fragments: KFXFragments) {
        let lists = fragments.singleton(KFXSymbol.navigation)?.listValue ?? []
        // The default reading order's navigation, else the first.
        let chosen = lists.first { $0.structValue?[Self.readingOrderNameField]?.symbolID == KFXSymbol.defaultReadingOrder }
            ?? lists.first
        var unitsRead = 0
        for container in chosen?.structValue?[Self.containersField]?.listValue ?? [] {
            guard let members = container.structValue, let type = members[Self.containerTypeField]?.symbolID else { continue }
            let name = members[Self.containerNameField]?.stringValue
            if type == Self.pageListType && name == Self.approximatePageList { continue }
            guard [Self.tableOfContentsType, Self.pageListType, Self.headingsType].contains(type) else { continue }

            // A stack of units still to read, the first on top; nested units
            // are pushed in reverse so they are read in order.
            var stack = (members[Self.containerUnitsField]?.listValue ?? []).reversed().map { Pending(unit: $0, depth: 1, level: nil) }
            while let pending = stack.popLast() {
                unitsRead += 1
                guard unitsRead <= Self.maximumUnits else { break }
                guard let unit = pending.unit.structValue else { continue }
                let children = unit[Self.containerUnitsField]?.listValue ?? []

                if type == Self.headingsType {
                    // A typed unit names the level; the units under it inherit it.
                    let level = pending.level ?? Self.headingLevel(of: unit)
                    if let level, let node = Self.position(of: unit)?.node, headingLevels[node] == nil {
                        headingLevels[node] = level
                    }
                    for child in children.reversed() { stack.append(Pending(unit: child, depth: pending.depth + 1, level: level)) }
                    continue
                }

                if let position = Self.position(of: unit) {
                    let label = Self.label(of: unit)
                    let entry = Entry(label: label, node: position.node, offset: position.offset, depth: pending.depth)
                    if type == Self.tableOfContentsType {
                        if !label.isEmpty { contents.append(entry) }
                    } else if pages.count < MarkdownPageMarker.maximumPagesPerBook {
                        pages.append(entry)
                    }
                }
                for child in children.reversed() { stack.append(Pending(unit: child, depth: pending.depth + 1, level: nil)) }
            }
        }
    }

    /// The level a headings unit names, 1 to 6, nil when it names none.
    private static func headingLevel(of unit: IonStruct) -> Int? {
        guard let symbol = unit[unitTypeField]?.symbolID else { return nil }
        let level = symbol - firstHeadingLevelUnit + 1
        return (1...6).contains(level) ? level : nil
    }

    /// The position a unit points at.
    private static func position(of unit: IonStruct) -> (node: Int, offset: Int)? {
        guard let position = unit[unitPositionField]?.structValue,
              let node = position[KFXSymbol.positionNode]?.intValue else { return nil }
        return (node, max(0, position[KFXSymbol.positionOffset]?.intValue ?? 0))
    }

    /// The label of a unit, white space made single spaces.
    private static func label(of unit: IonStruct) -> String {
        let text = unit[unitRepresentationField]?.structValue?[unitLabelField]?.stringValue ?? ""
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Targets

    /// The positions the walk writes anchors at: the contents' entries,
    /// those of the page list when pages are wanted, and where links point.
    func targets(includingPages: Bool) -> KFXTargets {
        var targets = KFXTargets()
        for entry in contents { targets.add(node: entry.node, offset: entry.offset) }
        if includingPages { for entry in pages { targets.add(node: entry.node, offset: entry.offset) } }
        for link in linkTargets { targets.add(node: link.node, offset: link.offset) }
        return targets
    }
}
