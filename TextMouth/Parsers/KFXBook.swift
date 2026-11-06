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
    /// - Throws: `KFXError.partOfABook` and `.noFlowingText` for the books
    ///   described above, `MOBIError.damaged` for one that stops short or
    ///   names what it lacks, `DocumentTooLargeError` for one whose text
    ///   passes `DocumentByteLimit`.
    init(containers: [KFXContainer]) throws {
        var fragmentBudget = KFXContainer.maximumValues
        var decoded: [KFXContainer.Fragment] = []
        for container in containers {
            decoded += try container.fragments(budget: &fragmentBudget)
        }
        let fragments = KFXFragments(decoded)
        let marks = KFXMetadata(fragments)
        metadata = marks.metadata

        // A container with no sections, storylines, or reading order is the
        // book's metadata or resources, not its text.
        guard let order = Self.readingOrder(in: fragments) else {
            if fragments.holds(KFXSymbol.section) || fragments.holds(KFXSymbol.storyline) {
                throw MOBIError.damaged("the book has no reading order")
            }
            throw KFXError.partOfABook
        }
        if marks.hasNoFlowingText(in: fragments) { throw KFXError.noFlowingText }

        var walk = KFXWalk(fragments: fragments)
        var sections: [MOBIBook.Section] = []
        var holdsText = false
        for name in order {
            let walked = try walk.section(named: name)
            holdsText = holdsText || walked.holdsText
            sections.append(MOBIBook.Section(title: nil, html: walked.html, headingTargets: [:]))
        }
        // Sections that are all pictures: no words to read.
        if !holdsText { throw KFXError.noFlowingText }
        self.sections = sections
    }

    /// Reads the single container in `bytes`.
    /// - Throws: As `init(containers:)`, and what `KFXContainer.init(bytes:)` throws.
    init(bytes: [UInt8]) throws {
        try self.init(containers: [KFXContainer(bytes: bytes)])
    }

    /// What the container in `bytes` says about itself, read without walking
    /// its text. A book that is in a set, or has no flowing text, still names
    /// its title and author.
    /// - Throws: `MOBIError` for a file that is not a container.
    static func metadata(in bytes: [UInt8]) throws -> MOBIBook.Metadata {
        let container = try KFXContainer(bytes: bytes)
        var budget = KFXContainer.maximumValues
        return KFXMetadata(KFXFragments(try container.fragments(budget: &budget))).metadata
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
