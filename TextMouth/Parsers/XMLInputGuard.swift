import Foundation

// MARK: - Refusing XML That Hurts Before the Parser Reads It

/// Two checks of the raw bytes of an XML part, made before `XMLParser` sees
/// them, for the two hazards a hostile part has that the parser does not
/// guard against. Both are linear in the size of the part and need no tree.
/// The OpenDocument and Word 2003 XML readers ask both (`OfficeXMLReader`).
/// Every reader that parses with `PackageSAXParser` (DOCX, DAISY, SSML) asks
/// for the start tag limit there, and the EPUB reader in `readingXML`. They do
/// not ask for the document type check: DAISY's DTBook files declare one.
///
/// - **A document type declaration.** It can declare entities that expand
///   into gigabytes (a 10 MB entity referenced millions of times), and an
///   external entity whose reference silently drops the words after it. None
///   of the formats uses one, so a part that has one is refused. It can only
///   come in the prolog, before the root element, so only the prolog is
///   searched: `<!DOCTYPE` in a comment, in a CDATA section, or in text is
///   no declaration and is not refused. The prolog is read in the part's own
///   encoding: UTF-8, Latin-1 and the like (ASCII-compatible), UTF-16 either
///   way round, and UTF-32.
/// - **A very long start tag.** `XMLParser` takes time that grows with the
///   square of the attributes in one start tag (200,000 attributes: 17
///   seconds; a start tag of a megabyte: 5 seconds, and 64 of them minutes
///   in which Cancel cannot land). The longest start tag in 2,067 parts of
///   535 real files is 2,166 bytes (the root of a document, which declares its
///   namespaces), so a start tag of 64 KB, 30 times that, is refused: it
///   costs the parser a fiftieth of a second.
enum XMLInputGuard {
    /// The longest start tag, in bytes of the part, that is read: 64 KB, 30
    /// times the longest of 2,067 real parts (2,166 bytes).
    static let longestStartTag = 65_536

    /// What a part with a start tag over the limit is refused for, as the
    /// reason that completes "The file is damaged or incomplete: …"
    /// (`PackageDamage.message`).
    static let longStartTagProblem = "it has a start tag longer than 64 KB, which no real file has"

    // MARK: Code units

    /// The characters of a part, whatever its encoding, as ASCII values:
    /// a code unit that is not ASCII reads as `other`, which no markup uses.
    private struct CodeUnits {
        /// The value of a code unit that is not ASCII.
        static let other: UInt8 = 0xFF

        let bytes: UnsafeBufferPointer<UInt8>
        /// Bytes per code unit: 1, 2, or 4.
        let width: Int
        /// Where the ASCII byte of a code unit is: 0 for little-endian or
        /// one byte, `width - 1` for big-endian.
        let asciiOffset: Int
        /// Where the first character is (after a byte-order mark).
        let start: Int

        /// How many code units the part holds.
        var count: Int { (bytes.count - start) / width }

        /// The ASCII value of code unit `index`, or `other`.
        func unit(_ index: Int) -> UInt8 {
            let base = start + index * width
            guard width > 1 else { return bytes[base] }
            for offset in 0..<width where offset != asciiOffset && bytes[base + offset] != 0 { return Self.other }
            return bytes[base + asciiOffset]
        }

        /// The encoding of `bytes` as its first bytes show it (XML 1.0,
        /// appendix F): a byte-order mark, or the `<` of `<?xml` as 0 and 60.
        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            func at(_ i: Int) -> UInt8 { i < bytes.count ? bytes[i] : 1 }
            var shape = (width: 1, asciiOffset: 0, start: 0)
            if bytes.count >= 4, at(0) == 0xFF, at(1) == 0xFE, at(2) == 0, at(3) == 0 {
                shape = (4, 0, 4)
            } else if bytes.count >= 4, at(0) == 0, at(1) == 0, at(2) == 0xFE, at(3) == 0xFF {
                shape = (4, 3, 4)
            } else if at(0) == 0xFF, at(1) == 0xFE {
                shape = (2, 0, 2)
            } else if at(0) == 0xFE, at(1) == 0xFF {
                shape = (2, 1, 2)
            } else if at(0) == 0xEF, at(1) == 0xBB, at(2) == 0xBF {
                shape = (1, 0, 3)
            } else if at(0) == 0, at(1) == 0, at(2) == 0, at(3) == 0x3C {
                shape = (4, 3, 0)
            } else if at(0) == 0x3C, at(1) == 0, at(2) == 0, at(3) == 0 {
                shape = (4, 0, 0)
            } else if at(0) == 0, at(1) == 0x3C {
                shape = (2, 1, 0)
            } else if at(0) == 0x3C, at(1) == 0 {
                shape = (2, 0, 0)
            }
            width = shape.width
            asciiOffset = shape.asciiOffset
            start = shape.start
        }

        /// Whether the code units from `index` are the ASCII text `text`.
        func matches(_ text: StaticString, at index: Int) -> Bool {
            let length = text.utf8CodeUnitCount
            guard index + length <= count else { return false }
            return text.withUTF8Buffer { expected in
                for offset in 0..<length where unit(index + offset) != expected[offset] { return false }
                return true
            }
        }

        /// The index just after the first `terminator` at or after `index`,
        /// or the end of the part.
        func skip(to terminator: StaticString, from index: Int) -> Int {
            var i = index
            while i < count {
                if matches(terminator, at: i) { return i + terminator.utf8CodeUnitCount }
                i += 1
            }
            return count
        }
    }

    // MARK: The prolog

    /// Whether the part declares a document type: a `<!DOCTYPE` in its
    /// prolog, which is read up to the first start tag (the XML declaration,
    /// comments, processing instructions, and white space come before it).
    static func declaresDocumentType(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let units = CodeUnits(raw.bindMemory(to: UInt8.self))
            var i = 0
            while i < units.count {
                let c = units.unit(i)
                guard c == UInt8(ascii: "<") else { i += 1; continue }
                if units.matches("<!--", at: i) {
                    i = units.skip(to: "-->", from: i + 4)
                } else if units.matches("<?", at: i) {
                    i = units.skip(to: "?>", from: i + 2)
                } else if units.matches("<!DOCTYPE", at: i) {
                    return true
                } else {
                    // The root element (or anything else): the prolog is over.
                    return false
                }
            }
            return false
        }
    }

    // MARK: Start tags

    /// Whether any start tag of the part is longer than `limit` code units
    /// (its attribute values, which may hold `>`, are skipped as quoted
    /// text). Comments, processing instructions, CDATA sections, declarations,
    /// and end tags are skipped whole.
    static func hasStartTag(longerThan limit: Int = longestStartTag, in data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let units = CodeUnits(raw.bindMemory(to: UInt8.self))
            let end = units.count
            var i = 0
            while i < end {
                guard units.unit(i) == UInt8(ascii: "<") else { i += 1; continue }
                if units.matches("<!--", at: i) {
                    i = units.skip(to: "-->", from: i + 4)
                } else if units.matches("<![CDATA[", at: i) {
                    i = units.skip(to: "]]>", from: i + 9)
                } else if units.matches("<?", at: i) {
                    i = units.skip(to: "?>", from: i + 2)
                } else if units.matches("<!", at: i) || units.matches("</", at: i) {
                    i = units.skip(to: ">", from: i + 2)
                } else {
                    // A start tag: to the `>` that is not inside quotes.
                    var j = i + 1
                    var quote: UInt8 = 0
                    while j < end {
                        let c = units.unit(j)
                        if quote != 0 {
                            if c == quote { quote = 0 }
                        } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                            quote = c
                        } else if c == UInt8(ascii: ">") {
                            break
                        }
                        j += 1
                        if j - i > limit { return true }
                    }
                    i = j + 1
                }
            }
            return false
        }
    }
}
