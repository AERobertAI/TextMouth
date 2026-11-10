import Foundation

// MARK: - Refusing XML That Hurts Before the Parser Reads It

/// Checks of the raw bytes of an XML part, made before `XMLParser` sees it,
/// for the hazards a hostile part has that the parser does not guard against.
/// Each is linear in the size of the part and needs no tree. The OpenDocument
/// and Word 2003 XML readers refuse any document type declaration
/// (`OfficeXMLReader`). Every reader that parses with `PackageSAXParser`
/// (DOCX, DAISY, SSML) and the EPUB reader (`readingXML`) ask `problem(with:)`.
/// The feed and OPML readers ask for the attributes and the encoding only
/// (`encodingProblem(of:)`, `hasTag(withMoreAttributesThan:in:)`), since old
/// feeds declare entities of their own.
///
/// - **A document type declaration.** It can declare entities that expand
///   into gigabytes (a 10 MB entity referenced millions of times), and an
///   external entity whose reference silently drops the words after it. It
///   can only come in the prolog, before the root element, so only the prolog
///   is searched: `<!DOCTYPE` in a comment, in a CDATA section, or in text is
///   no declaration and is not refused. The prolog is read in the part's own
///   encoding: UTF-8, Latin-1 and the like (ASCII-compatible), UTF-16 either
///   way round, and UTF-32. ODT and Word 2003 XML have no use for one and
///   refuse any. DOCX, EPUB, DAISY, and SSML refuse one with an internal
///   subset (`[ … ]`, the definitions of its own); a DTBook or NCX file names
///   an external type (`PUBLIC "…" "…"`), which is no hazard, and is read.
/// - **Too many attributes in one tag.** `XMLParser` takes time that grows
///   with the square of the attributes in one start tag (200,000 attributes:
///   11 to 17 seconds, and 64 of such tags minutes in which Cancel cannot
///   land). The length of an attribute does not matter: a value of 8 MB costs
///   a hundredth of a second, and a real document holds a whole picture in
///   one (`o:gfxdata`, 267 KB). So the attributes are counted, outside the
///   quotes of their values. The most in any of 3.98 million real start tags,
///   in 25,019 parts, is 38; 1,024 is 27 times that, and costs the parser
///   about a fifth of a millisecond a tag.
/// - **An encoding the guard cannot see through.** The guard reads bytes as
///   ASCII. A stateful or exotic encoding (UTF-7, ISO-2022-*, HZ, EBCDIC, and
///   every alias the parser knows for them) writes `<` and quotes in other
///   bytes, so what the guard does not see, the parser does. A list of the
///   encodings to refuse always misses an alias, so only the encodings whose
///   bytes the guard can see through are allowed (`seesThrough(_:)`). All
///   25,163 encoding declarations of 25,642 XML parts in 1,849 real files
///   are UTF-8 (in two spellings), windows-1252, or ISO-8859-1.
enum XMLInputGuard {
    /// The most attributes one tag may hold: 1,024, 27 times the most in any
    /// real start tag (38).
    static let mostAttributesInATag = 1_024

    /// What a part with a tag of more attributes is refused for, as the
    /// reason that completes "The file is damaged or incomplete: …"
    /// (`PackageDamage.message`).
    static let tooManyAttributesProblem = "it has a tag with too many attributes for TextMouth to read safely"

    /// What a part is refused for.
    enum Problem: Equatable, Sendable {
        /// A tag holds more than `mostAttributesInATag` attributes.
        case tooManyAttributes
        /// The document type declaration has an internal subset: entities of
        /// its own.
        case ownDefinitions
        /// The part is in an encoding the guard cannot see through, by the
        /// name it declares (or "EBCDIC").
        case encoding(String)
    }

    /// The sentence a person hears for a part that is refused although it is
    /// not damaged (a subset or an encoding), or nil for too many attributes,
    /// which is damage in the format's own damaged-file sentence
    /// (`tooManyAttributesProblem`).
    /// - Parameters:
    ///   - file: The part's path inside the package.
    ///   - container: What holds it, as the format's sentences say ("this
    ///     document", "this EPUB book", "this DAISY book").
    ///   - original: What the person opens again ("the document", "the book").
    static func refusalSentence(for problem: Problem, file: String, in container: String, original: String) -> String? {
        switch problem {
        case .tooManyAttributes:
            return nil
        case .ownDefinitions:
            return "TextMouth can't safely read the file \u{201C}\(file)\u{201D} in \(container), because it defines entities "
                + "of its own. Open \(original) in the program that made it, save it again, then import it again."
        case .encoding(let name):
            return "TextMouth can't safely read the file \u{201C}\(file)\u{201D} in \(container), because it is written in the "
                + "\(name) encoding. Save it as UTF-8, then import it again."
        }
    }

    // MARK: Code units

    /// The characters of a part, whatever its encoding, as ASCII values:
    /// a code unit that is not ASCII reads as `other`, which no markup uses.
    struct CodeUnits {
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

        /// The first index at or after `index` whose code unit satisfies
        /// `match` and is not inside quotes, or nil. A quote (`"` or `'`)
        /// runs to the same quote, or to the end of the part. This is the one
        /// quote-aware scan of the guard and of every reader that finds
        /// attributes with it.
        func firstIndex(from index: Int, outsideQuotesWhere match: (UInt8) -> Bool) -> Int? {
            var i = index
            while i < count {
                let c = unit(i)
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    i += 1
                    while i < count, unit(i) != c { i += 1 }
                    i += 1
                } else if match(c) {
                    return i
                } else {
                    i += 1
                }
            }
            return nil
        }

        /// The index just after the end of the declaration (`<!DOCTYPE …>`)
        /// whose body begins at `index`: its first `>` outside quotes and
        /// outside brackets, or the end of the part. Comments inside an
        /// internal subset are not looked for, since a part with a subset is
        /// refused before its tags are counted (`problem(with:)`).
        func skipDeclaration(from index: Int) -> Int {
            var i = index
            var depth = 0
            while let at = firstIndex(from: i, outsideQuotesWhere: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "]") || $0 == UInt8(ascii: ">") }) {
                switch unit(at) {
                case UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "]"): depth = max(0, depth - 1)
                default: if depth == 0 { return at + 1 }
                }
                i = at + 1
            }
            return count
        }
    }

    // MARK: Walking the start tags

    /// How many start tags `walkStartTags` walks between two asks whether the import was cancelled: a few
    /// milliseconds of the walk, even in a Debug build, and the ask (a task-local and a lock) costs nothing beside them.
    private static let tagsBetweenCancelChecks = 4_096

    /// What a visitor of an attribute tells `walkStartTags`.
    enum ScanAction {
        /// Go on with the tag, after the `=`.
        case proceed
        /// Go on with the tag at this index (after a value the visitor read).
        case continueAt(Int)
        /// Stop the walk.
        case stop
    }

    /// Walks the start tags of the part, in order, and the `=` of each
    /// attribute that stands outside quotes. Comments, CDATA sections,
    /// processing instructions, declarations (by their quotes and brackets),
    /// and end tags are skipped whole, and the text between tags is not read,
    /// so a `<` or `=` in them begins nothing. A tag ends at its first `>`
    /// outside quotes. One pass, each code unit read once.
    /// - Parameters:
    ///   - begin: Called as a start tag begins, with the index of the first
    ///     code unit of its name.
    ///   - attribute: Called for each `=` outside quotes, with its index and
    ///     the index of the tag's name; answers what to do next.
    ///   - cancelled: Asked every `tagsBetweenCancelChecks` start tags, when
    ///     given; the walk ends, as if the part ended there, once it answers
    ///     true. A caller that passes it must itself refuse to go on with a
    ///     part whose scan was cut short (`problem(with:stoppingWhenCancelled:)`
    ///     and `PackageSAXParser.parseDocument()` do).
    static func walkStartTags(
        in units: CodeUnits,
        begin: (_ nameStart: Int) -> Void,
        attribute: (_ equals: Int, _ nameStart: Int) -> ScanAction,
        cancelled: (() -> Bool)? = nil
    ) {
        let end = units.count
        var i = 0
        var tags = 0
        while i < end {
            guard units.unit(i) == UInt8(ascii: "<") else { i += 1; continue }
            if units.matches("<!--", at: i) {
                i = units.skip(to: "-->", from: i + 4)
            } else if units.matches("<![CDATA[", at: i) {
                i = units.skip(to: "]]>", from: i + 9)
            } else if units.matches("<?", at: i) {
                i = units.skip(to: "?>", from: i + 2)
            } else if units.matches("<!", at: i) {
                i = units.skipDeclaration(from: i + 2)
            } else if units.matches("</", at: i) {
                i = units.skip(to: ">", from: i + 2)
            } else {
                tags &+= 1
                if tags % tagsBetweenCancelChecks == 0, cancelled?() == true { return }
                begin(i + 1)
                var j = i + 1
                tag: while true {
                    guard let at = units.firstIndex(from: j, outsideQuotesWhere: { $0 == UInt8(ascii: "=") || $0 == UInt8(ascii: ">") }) else {
                        i = end
                        break tag
                    }
                    if units.unit(at) == UInt8(ascii: ">") {
                        i = at + 1
                        break tag
                    }
                    switch attribute(at, i + 1) {
                    case .proceed: j = at + 1
                    case .continueAt(let next): j = next
                    case .stop: return
                    }
                }
            }
        }
    }

    // MARK: The prolog

    /// What the prolog of a part declares: read up to the first start tag
    /// (the XML declaration, comments, processing instructions, and white
    /// space come before it).
    private struct Prolog {
        /// Whether a `<!DOCTYPE` is there.
        var declaresDocumentType = false
        /// Whether that declaration holds an internal subset: a `[` outside
        /// the quotes of its identifiers, before its `>`.
        var hasInternalSubset = false
    }

    /// The prolog of `data`, in its own encoding.
    private static func prolog(of data: Data) -> Prolog {
        data.withUnsafeBytes { raw in
            let units = CodeUnits(raw.bindMemory(to: UInt8.self))
            var i = 0
            while i < units.count {
                guard units.unit(i) == UInt8(ascii: "<") else { i += 1; continue }
                if units.matches("<!--", at: i) {
                    i = units.skip(to: "-->", from: i + 4)
                } else if units.matches("<?", at: i) {
                    i = units.skip(to: "?>", from: i + 2)
                } else if units.matches("<!DOCTYPE", at: i) {
                    // The declaration ends at its first `>` outside quotes,
                    // unless a `[` outside quotes comes first: the subset.
                    let stop = units.firstIndex(from: i + 9) { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: ">") }
                    return Prolog(declaresDocumentType: true, hasInternalSubset: stop.map { units.unit($0) == UInt8(ascii: "[") } ?? false)
                } else {
                    // The root element (or anything else): the prolog is over.
                    return Prolog()
                }
            }
            return Prolog()
        }
    }

    /// Whether the part declares a document type: a `<!DOCTYPE` in its
    /// prolog.
    static func declaresDocumentType(_ data: Data) -> Bool {
        prolog(of: data).declaresDocumentType
    }

    /// Whether the part's document type declaration holds an internal subset
    /// (`<!DOCTYPE d [ … ]>`): definitions of its own, entities and the
    /// default values of attributes, that the parser expands. An identifier
    /// alone (`<!DOCTYPE dtbook PUBLIC "…" "…">`, which DAISY and NCX files
    /// have) holds none.
    static func declaresInternalSubset(_ data: Data) -> Bool {
        prolog(of: data).hasInternalSubset
    }

    // MARK: Encodings

    /// The encodings, by their names in capitals (and the same with the
    /// aliases the parser knows for them), that the guard can see through:
    /// every byte below 0x40 is ASCII and nothing else, so `<`, `=`, and the
    /// quotes are where the guard reads them. UTF-8, UTF-16, and UTF-32 are
    /// read by shape (`CodeUnits`). The ISO-8859 and Windows code pages,
    /// KOI8, the Macintosh set, and the East Asian multi-byte sets listed
    /// (Shift_JIS, EUC-JP, EUC-KR, GB2312, GBK, GB18030, Big5) keep ASCII's
    /// bytes whole: their lead and trail bytes are all 0x40 or more, but for
    /// the digits (0x30 to 0x39) of GB18030's four-byte forms, which are not
    /// markup either.
    private static let narrowEncodings: Set<String> = [
        "UTF-8", "UTF8",
        "US-ASCII", "ASCII", "ANSI_X3.4-1968", "ISO646-US",
        "LATIN1", "LATIN-1", "L1", "IBM819", "CP819", "LATIN2", "LATIN3", "LATIN4", "LATIN5", "LATIN6", "LATIN7",
        "LATIN8", "LATIN9", "LATIN10",
        "KOI8-R", "KOI8-U", "MACINTOSH", "MAC", "MACROMAN", "X-MAC-ROMAN",
        "SHIFT_JIS", "SHIFT-JIS", "SJIS", "X-SJIS", "MS_KANJI", "WINDOWS-31J", "CP932",
        "EUC-JP", "EUCJP", "X-EUC-JP", "EUC-KR", "EUCKR",
        "GB2312", "GBK", "GB18030", "CP936", "X-GBK", "BIG5", "BIG-5", "BIG5-HKSCS",
    ]

    /// The names of the two-byte encodings, which the part must be in.
    private static let sixteenBitEncodings: Set<String> = [
        "UTF-16", "UTF-16LE", "UTF-16BE", "UTF16", "UTF16LE", "UTF16BE", "UCS-2", "ISO-10646-UCS-2",
    ]

    /// The names of the four-byte encodings, which the part must be in.
    private static let thirtyTwoBitEncodings: Set<String> = [
        "UTF-32", "UTF-32LE", "UTF-32BE", "UTF32", "UTF32LE", "UTF32BE", "UCS-4", "ISO-10646-UCS-4",
    ]

    /// Whether the guard can see through the encoding `name` (in capitals)
    /// for a part whose code units are `width` bytes wide (`width` nil when
    /// the text was decoded already and the declaration only a leftover): the
    /// allow-list. The Windows code pages 1250 to 1258 and the ISO-8859 sets
    /// (written `ISO-8859-n`, `ISO8859-n`, or `ISO_8859-n`) are taken by their
    /// pattern.
    static func seesThrough(_ name: String, width: Int?) -> Bool {
        if narrowEncodings.contains(name) { return true }
        if sixteenBitEncodings.contains(name) { return width == nil || width == 2 }
        if thirtyTwoBitEncodings.contains(name) { return width == nil || width == 4 }
        for prefix in ["ISO-8859-", "ISO8859-", "ISO_8859-"] where name.hasPrefix(prefix) {
            let number = name.dropFirst(prefix.count)
            return (1...2).contains(number.count) && number.allSatisfy(\.isASCIINumber)
        }
        for prefix in ["WINDOWS-125", "CP125"] where name.hasPrefix(prefix) {
            return name.count == prefix.count + 1 && "012345678".contains(name.last!)
        }
        return false
    }

    /// The encoding a part declares, as written (at most 40 characters, a
    /// code unit that is not ASCII shown as "?"), or "EBCDIC" for a part
    /// that begins with EBCDIC's `<?xm` (the bytes `4C 6F A7 94`); nil when
    /// it declares none. White space around the `=` is any XML white space,
    /// the line ends included.
    private static func declaredEncoding(of units: CodeUnits) -> String? {
        if units.bytes.count >= 4, units.bytes[0] == 0x4C, units.bytes[1] == 0x6F, units.bytes[2] == 0xA7, units.bytes[3] == 0x94 {
            return "EBCDIC"
        }
        guard units.matches("<?xml", at: 0) else { return nil }
        func isSpace(_ unit: UInt8) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        // The declaration is the processing instruction at the start.
        let declarationEnd = units.skip(to: "?>", from: 0)
        var i = 5
        while i + 8 <= declarationEnd {
            guard units.matches("encoding", at: i) else { i += 1; continue }
            // `encoding`, white space, `=`, white space, a quote.
            var j = i + 8
            while j < declarationEnd, isSpace(units.unit(j)) { j += 1 }
            guard j < declarationEnd, units.unit(j) == UInt8(ascii: "=") else { i += 1; continue }
            j += 1
            while j < declarationEnd, isSpace(units.unit(j)) { j += 1 }
            guard j < declarationEnd, units.unit(j) == UInt8(ascii: "\"") || units.unit(j) == UInt8(ascii: "'") else {
                i += 1
                continue
            }
            let quote = units.unit(j)
            j += 1
            var name = ""
            while j < declarationEnd, units.unit(j) != quote, name.count < 40 {
                let unit = units.unit(j)
                name.append(unit == CodeUnits.other || unit < 0x20 ? "?" : Character(UnicodeScalar(unit)))
                j += 1
            }
            return name
        }
        return nil
    }

    /// The encoding problem of a part, nil when the guard can see through the
    /// encoding it declares (or when it declares none): EBCDIC, a name that is
    /// not on the allow-list (`seesThrough(_:width:)`), or a two- or
    /// four-byte encoding the part is not shaped as. With `isDecodedText` the
    /// bytes are the UTF-8 of text that was decoded already (an EPUB's
    /// package document), so a declared UTF-16 is a leftover and the shape is
    /// not asked.
    static func encodingProblem(of data: Data, isDecodedText: Bool = false) -> Problem? {
        data.withUnsafeBytes { raw in
            let units = CodeUnits(raw.bindMemory(to: UInt8.self))
            guard let name = declaredEncoding(of: units) else { return nil }
            if name != "EBCDIC", seesThrough(name.uppercased(), width: isDecodedText ? nil : units.width) { return nil }
            return .encoding(name)
        }
    }

    // MARK: Start tags

    /// Whether any start tag of the part holds more than `limit` attributes.
    /// An attribute is an `=` outside the quotes of a value, so a value of
    /// any length (a picture in `o:gfxdata`) is one, and costs nothing
    /// (`walkStartTags`).
    ///
    /// With `cancelled`, the scan ends early once it answers true, and then
    /// says only that it found no such tag *so far*: the caller must not
    /// treat the part as checked (`problem(with:stoppingWhenCancelled:)`).
    static func hasTag(
        withMoreAttributesThan limit: Int = mostAttributesInATag,
        in data: Data,
        cancelled: (() -> Bool)? = nil
    ) -> Bool {
        data.withUnsafeBytes { raw in
            let units = CodeUnits(raw.bindMemory(to: UInt8.self))
            var attributes = 0
            var exceeded = false
            walkStartTags(
                in: units,
                begin: { _ in attributes = 0 },
                attribute: { _, _ in
                    attributes += 1
                    if attributes > limit {
                        exceeded = true
                        return .stop
                    }
                    return .proceed
                },
                cancelled: cancelled)
            return exceeded
        }
    }

    // MARK: Asking all of them

    /// `problem(with:)` for a document that may declare entities of its own,
    /// as old RSS feeds do: only the encoding and the attributes are asked.
    static func problemLeavingDefinitions(with data: Data) -> Problem? {
        if let encoding = encodingProblem(of: data) { return encoding }
        if hasTag(withMoreAttributesThan: mostAttributesInATag, in: data) { return .tooManyAttributes }
        return nil
    }

    /// The reason a feed or OPML reader gives for `problem`, to complete its
    /// own sentence about a damaged file ("The feed is damaged at line 1: …").
    static func reason(for problem: Problem) -> String {
        switch problem {
        case .tooManyAttributes:
            return tooManyAttributesProblem
        case .ownDefinitions:
            return "it defines entities of its own, which TextMouth cannot read safely"
        case .encoding(let name):
            return "it is written in the \(name) encoding, which TextMouth cannot read safely"
        }
    }

    /// Why a part must not be handed to `XMLParser` or `XMLDocument`; nil when
    /// it may be. For the parts of a package: DOCX, EPUB, DAISY, and SSML. The
    /// encoding first, since the other checks read the part as ASCII, then the
    /// subset, then the attributes. A document type that only names an
    /// external one (DAISY and NCX files have those) is fine.
    ///
    /// The attribute count is the one long pass (all of the part: seconds for
    /// a very large one in a Debug build). With `stoppingWhenCancelled` it
    /// ends as soon as the import running on this thread is cancelled, and
    /// then answers nil though the part was not checked to its end: the
    /// caller must go on to ask `ImportCancellation.throwIfCancelled()` before
    /// it hands the part to a parser (the flag, once set, stays set, so that
    /// ask throws), as `PackageSAXParser.parseDocument()` does.
    static func problem(
        with data: Data,
        isDecodedText: Bool = false,
        stoppingWhenCancelled: Bool = false
    ) -> Problem? {
        if let encoding = encodingProblem(of: data, isDecodedText: isDecodedText) { return encoding }
        if declaresInternalSubset(data) { return .ownDefinitions }
        let cancelled: (() -> Bool)? = stoppingWhenCancelled ? { ImportCancellation.current?.isCancelled == true } : nil
        if hasTag(withMoreAttributesThan: mostAttributesInATag, in: data, cancelled: cancelled) { return .tooManyAttributes }
        return nil
    }
}

private extension Character {
    /// Whether the character is one of the ASCII digits.
    var isASCIINumber: Bool { "0123456789".contains(self) }
}
