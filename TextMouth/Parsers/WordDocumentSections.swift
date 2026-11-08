import Foundation

// MARK: - Sections

/// The sections of a Word 97-2003 document ([MS-DOC] 2.8.25, the PlcfSed):
/// where each ends, and how each begins. A section's last character is a
/// form feed (0x0C), the same character an explicit page break is, so the
/// table is how the two are told apart: a form feed that ends a section is a
/// section break, which starts a page only if the next section begins on a
/// new page (`sprmSBkc` of its properties); any other form feed is a page
/// break.
struct WordSections {

    /// The index of the section that ends right before each character
    /// position (the position after its break mark).
    private let sectionEndingBefore: [Int: Int]
    /// Whether each section begins on a new page.
    private let beginsOnNewPage: [Bool]

    /// A document with no sections: every form feed is a page break.
    static let none = WordSections(sectionEndingBefore: [:], beginsOnNewPage: [])

    private init(sectionEndingBefore: [Int: Int], beginsOnNewPage: [Bool]) {
        self.sectionEndingBefore = sectionEndingBefore
        self.beginsOnNewPage = beginsOnNewPage
    }

    /// Reads the PlcfSed at `range` in `table`; the properties of each
    /// section are in the `WordDocument` stream.
    /// - Throws: `OLEDamage` when the table or a section's properties do not fit.
    init(range: Range<Int>, table: OLEBytes, document: OLEBytes, dialect: WordSprm.Dialect = .modern) throws {
        // A PLC of n+1 character positions and n descriptors of 12 bytes.
        let length = range.count
        guard length >= 4, (length - 4) % 16 == 0 else { throw OLEDamage(reason: "the section table is \(length) bytes long") }
        let count = (length - 4) / 16
        var ends: [Int: Int] = [:]
        var beginsOnNewPage: [Bool] = []
        beginsOnNewPage.reserveCapacity(count)
        for index in 0..<count {
            ends[try table.u32(range.lowerBound + (index + 1) * 4)] = index
            // The descriptor: 2 bytes, the offset of the properties, 6 more.
            let propertiesOffset = try table.u32(range.lowerBound + (count + 1) * 4 + index * 12 + 2)
            beginsOnNewPage.append(try Self.beginsOnNewPage(propertiesAt: propertiesOffset, in: document, dialect: dialect))
        }
        self.sectionEndingBefore = ends
        self.beginsOnNewPage = beginsOnNewPage
    }

    /// Whether the section whose properties are at `offset` in `document`
    /// begins on a new page. A section with no properties (offset
    /// 0xFFFFFFFF) does; so does one that does not say.
    private static func beginsOnNewPage(propertiesAt offset: Int, in document: OLEBytes, dialect: WordSprm.Dialect) throws -> Bool {
        guard offset != 0xFFFF_FFFF else { return true }
        // The properties: a 16-bit size and the modifiers.
        let size = try document.u16(offset)
        var kind = 2
        WordSprm.forEach(in: try document.slice(offset: offset + 2, length: size), dialect: dialect) { opcode, operand in
            if opcode == WordSprm.sectionBreakKind, let value = operand.first { kind = Int(value) }
        }
        // 0 is continuous and 1 a new column; 2, 3, and 4 are a new page, an
        // even page, and an odd page.
        return kind >= 2
    }

    /// Whether the form feed at character position `position` ends a section
    /// (a section break, which also ends a paragraph) and is not a page break
    /// inside a paragraph.
    func endsSection(at position: Int) -> Bool {
        sectionEndingBefore[position + 1] != nil
    }

    /// Whether the form feed at character position `position` starts a new
    /// page: an explicit page break does; a section break does when the next
    /// section begins on a new page.
    func formFeedStartsPage(at position: Int) -> Bool {
        guard let section = sectionEndingBefore[position + 1] else { return true }
        // The last section's break has no section after it.
        guard section + 1 < beginsOnNewPage.count else { return true }
        return beginsOnNewPage[section + 1]
    }
}
