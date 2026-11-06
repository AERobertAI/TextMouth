import Foundation

/// A KFX book opened for reading: what it says about itself, and its text cut
/// into sections of HTML, one for each section of its reading order. This is
/// everything the book holds before the shared converter turns it into the
/// reading text (`MOBIParser.preparedBook`), and it is what a MOBI book
/// gives (`MOBIBook`), so both end in the same chapters.
///
/// It refuses what TextMouth does not read, before any text is walked: a
/// container that holds no text of its own, and a book with no flowing text
/// (a comic, a print replica, a magazine, a notebook, or only pictures).
struct KFXBook {

    var metadata: MOBIBook.Metadata
    var sections: [MOBIBook.Section]

    // MARK: Opening

    /// Reads the book whose containers are `containers`: one file, or the
    /// several of a set.
    /// - Parameters:
    ///   - sidecars: Containers found beside the book's main file. They add
    ///     what the main containers lack; one whose fragments do not decode
    ///     is left out, and the book reads without it.
    ///   - includesPages: Whether the book's print page list is written as
    ///     pages (the sections name where each page begins).
    /// - Throws: `KFXError.partOfABook` and `.noFlowingText` for the books
    ///   described above, `MOBIError.damaged` for one that stops short or
    ///   names what it lacks, `DocumentTooLargeError` for one whose text
    ///   passes `DocumentByteLimit`, `ImportCancelled`.
    init(containers: [KFXContainer], sidecars: [KFXContainer] = [], includesPages: Bool = true) throws {
        let fragments = KFXFragments(try Self.decoded(containers, sidecars: sidecars))
        let marks = KFXMetadata(fragments)
        metadata = marks.metadata

        // A container with no sections, storylines, or document data is the
        // book's metadata or resources, not its text (a flat metadata
        // fragment may hold a reading order, and is still metadata).
        guard fragments.holds(KFXSymbol.section) || fragments.holds(KFXSymbol.storyline)
                || fragments.holds(KFXSymbol.documentData) else {
            throw KFXError.partOfABook
        }
        guard let order = Self.readingOrder(in: fragments) else {
            throw MOBIError.damaged("the book has no reading order")
        }
        if marks.hasNoFlowingText(in: fragments) || Self.isAllFixedLayout(order, in: fragments) { throw KFXError.noFlowingText }

        let navigation = KFXNavigation(fragments)
        var walk = KFXWalk(
            fragments: fragments, targets: navigation.targets(includingPages: includesPages),
            headingLevels: navigation.headingLevels)
        var walked: [KFXWalk.Section] = []
        for name in order { walked.append(try walk.section(named: name)) }
        // Sections that are all pictures: no words to read.
        guard walked.contains(where: \.holdsText) else { throw KFXError.noFlowingText }

        sections = Self.sections(
            of: walked, names: order, navigation: navigation, fragments: fragments, includesPages: includesPages)
    }

    /// The fragments of the containers: the main ones strictly, the sidecars
    /// each by itself, leaving out one that does not decode.
    private static func decoded(_ containers: [KFXContainer], sidecars: [KFXContainer]) throws -> [KFXContainer.Fragment] {
        var budget = KFXContainer.maximumValues
        var decoded: [KFXContainer.Fragment] = []
        for container in containers { decoded += try container.fragments(budget: &budget) }
        for sidecar in sidecars {
            var spare = budget
            if let fragments = try? sidecar.fragments(budget: &spare) {
                budget = spare
                decoded += fragments
            }
        }
        return decoded
    }

    /// Whether every section of the reading order has page templates whose
    /// layouts are all fixed, magazine, scale-fit, or spread: a book of
    /// pictures laid out on pages. One such section (a fixed-layout cover)
    /// does not make a reflowable book fixed.
    private static func isAllFixedLayout(_ order: [String], in fragments: KFXFragments) -> Bool {
        guard !order.isEmpty else { return false }
        return order.allSatisfy { name in
            let templates = fragments[KFXSymbol.section, name]?.structValue?[KFXSymbol.pageTemplates]?.listValue ?? []
            return !templates.isEmpty && templates.allSatisfy { template in
                template.structValue?[KFXSymbol.templateLayout]?.symbolID.map(KFXSymbol.nonFlowingLayouts.contains) ?? false
            }
        }
    }

    /// Reads the single container in `bytes`.
    /// - Throws: As `init(containers:includesPages:)`, and what
    ///   `KFXContainer.init(bytes:)` throws.
    init(bytes: [UInt8], includesPages: Bool = true) throws {
        try self.init(containers: [KFXContainer(bytes: bytes)], includesPages: includesPages)
    }

    // MARK: Chapters

    /// The walked sections as the sections of a Kindle book, each with what
    /// the navigation says of it:
    /// - a contents entry that points at the start of a section titles it
    ///   (the first such entry; the way an EPUB's entry for a whole document
    ///   names its chapter);
    /// - every other contents entry is a heading kept as an annotation at
    ///   its place, one level deeper for each level of nesting;
    /// - each print page the page list names begins at its place;
    /// - a section the book does not begin (no contents entry, no heading at
    ///   its start, and no mark that its author began it) continues the
    ///   chapter before it: Amazon cuts a long document where its style asks
    ///   for a page break, and the cut is not a chapter.
    private static func sections(
        of walked: [KFXWalk.Section], names: [String], navigation: KFXNavigation,
        fragments: KFXFragments, includesPages: Bool
    ) -> [MOBIBook.Section] {
        // The section that holds each node the navigation points at.
        var sectionOfNode: [Int: Int] = [:]
        for (index, section) in walked.enumerated() {
            for node in section.targetNodeIDs where sectionOfNode[node] == nil { sectionOfNode[node] = index }
        }
        var titles: [Int: String] = [:]
        var headings = [[String: MarkdownHeadingAnnotation]](repeating: [:], count: walked.count)
        // A place is named once, by the first entry that points at it (as an
        // EPUB's contents name each destination once).
        var named: Set<String> = []
        var entered = Set<Int>()
        for entry in navigation.contents {
            guard let index = sectionOfNode[entry.node] else { continue }
            let anchor = KFXTargets.anchorID(node: entry.node, offset: entry.offset)
            guard named.insert(anchor).inserted else { continue }
            entered.insert(index)
            if entry.offset == 0, walked[index].startNodeIDs.contains(entry.node), titles[index] == nil {
                titles[index] = entry.label
            } else {
                headings[index][anchor] = MarkdownHeadingAnnotation(level: min(entry.depth, 6), text: entry.label)
            }
        }

        var pageTargets = [[String: MarkdownPageMarker]](repeating: [:], count: walked.count)
        var pageLabels = [[String: String]](repeating: [:], count: walked.count)
        if includesPages {
            var ordinal = 0
            for entry in navigation.pages {
                ordinal += 1
                guard let index = sectionOfNode[entry.node] else { continue }
                let anchor = KFXTargets.anchorID(node: entry.node, offset: entry.offset)
                // The first entry for a place names its page.
                guard pageTargets[index][anchor] == nil else { continue }
                pageTargets[index][anchor] = MarkdownPageMarker(label: entry.label, ordinal: ordinal)
                if !entry.label.isEmpty { pageLabels[index][anchor] = entry.label }
            }
        }

        // The sections the book's author began are marked by an auxiliary
        // fragment; a book whose producer writes none has no cuts to join.
        let marked = beganSections(in: fragments)
        let marksSections = !fragments.all(KFXSymbol.auxiliaryData).isEmpty

        var result: [MOBIBook.Section] = []
        for (index, section) in walked.enumerated() {
            let page = HTMLPageTargets(
                markers: pageTargets[index], sourceLabels: pageLabels[index], pageBreaksArePages: false)
            let continues = index > 0 && !result.isEmpty && marksSections && !entered.contains(index)
                && !section.startsWithHeading && !marked.contains(names[index])
            if continues {
                // Joined to the section before it: one chapter.
                result[result.count - 1].html += section.html
                result[result.count - 1].headingTargets.merge(headings[index]) { first, _ in first }
                result[result.count - 1].pages.markers.merge(page.markers) { first, _ in first }
                result[result.count - 1].pages.sourceLabels.merge(page.sourceLabels) { first, _ in first }
            } else {
                result.append(MOBIBook.Section(title: titles[index], html: section.html, headingTargets: headings[index], pages: page))
            }
        }
        return result
    }

    /// The names of the sections an auxiliary fragment marks as their
    /// author's own (`IS_TARGET_SECTION`). The fragment is named like its
    /// section, with "-ad" after.
    private static func beganSections(in fragments: KFXFragments) -> Set<String> {
        var names: Set<String> = []
        for (name, value) in fragments.all(KFXSymbol.auxiliaryData) where name.hasSuffix("-ad") {
            for entry in value.structValue?[KFXSymbol.categoryEntries]?.listValue ?? [] {
                guard let pair = entry.structValue, pair[KFXSymbol.entryKey]?.stringValue == "IS_TARGET_SECTION",
                      pair[KFXSymbol.entryValue]?.boolValue == true else { continue }
                names.insert(String(name.dropLast(3)))
            }
        }
        return names
    }

    /// What the containers of a book say about itself, read without walking
    /// its text. A book that has no flowing text, or whose text is in
    /// another container of its set, still names its title and author.
    /// - Throws: `MOBIError.damaged` for a container that does not read.
    static func metadata(of containers: [KFXContainer], sidecars: [KFXContainer] = []) throws -> MOBIBook.Metadata {
        KFXMetadata(KFXFragments(try decoded(containers, sidecars: sidecars))).metadata
    }

    // MARK: Reading order

    /// The names of the sections in the book's reading order, repeats left
    /// out, nil when the book names no reading order. The order is the one
    /// named `$351` (the default), else the first, in the document data and
    /// else in the flat metadata (older books).
    private static func readingOrder(in fragments: KFXFragments) -> [String]? {
        for holder in [fragments.singleton(KFXSymbol.documentData), fragments.singleton(KFXSymbol.flatMetadata)] {
            guard let orders = holder?.structValue?[KFXSymbol.readingOrders]?.listValue, !orders.isEmpty else { continue }
            let chosen = orders.first { $0.structValue?[KFXSymbol.readingOrderName]?.symbolID == KFXSymbol.defaultReadingOrder }
                ?? orders[0]
            let names = chosen.structValue?[KFXSymbol.readingOrderSections]?.listValue ?? []
            var seen: Set<String> = []
            return names.compactMap { $0.stringValue }.filter { seen.insert($0).inserted }
        }
        return nil
    }
}
