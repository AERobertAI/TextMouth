import Foundation
import SwiftSoup

/// Publication markup semantics shared by EPUB navigation discovery and
/// reading-text extraction, so both agree about which elements form a table of
/// contents and which elements never belong to the rendered reading flow.
///
/// The vocabulary follows EPUB 3.3 §7 (the navigation document, including §7.5
/// on the `hidden` attribute), the EPUB 3 Structural Semantics Vocabulary for
/// `epub:type`, and the DPUB-ARIA `role` values.
enum PublicationSemantics {
    /// Sectioning elements that can hold a table of contents, a page list, or
    /// landmarks. Checking the tag first keeps attribute scans off the hot path,
    /// because reading-text conversion consults these rules for every element.
    private static let navigationContainerTags: Set<String> = ["nav", "section", "div", "article"]

    /// Whether `element` is a sectioning element that may carry navigation semantics.
    static func isNavigationContainer(_ element: Element) -> Bool {
        navigationContainerTags.contains(element.tagName().lowercased())
    }

    /// Whether an `epub:type` attribute lists `token`. EPUB lets any prefix bind
    /// the OPS namespace, so this matches the attribute's local name (`*:type`)
    /// instead of assuming the conventional `epub:` prefix.
    ///
    /// `typeNames` are the attribute names of the element's document that end
    /// in ":type" (`typeAttributeNames(in:)`), when the document's markup was
    /// scanned for them: the element is then asked for each by name, which
    /// reads no other attribute and builds no list (the November 14, 2026
    /// speed-up, H6). Nil, as for an element of unknown markup, looks through
    /// all the element's attributes for one whose name ends in ":type".
    static func hasEPUBType(_ token: String, _ element: Element) -> Bool {
        hasEPUBType(token, element, typeNames: nil)
    }

    /// `hasEPUBType(_:_:)` for an element whose document's names are known.
    static func hasEPUBType(_ token: String, _ element: Element, typeNames: [String]?) -> Bool {
        if let typeNames {
            return typeNames.contains { containsToken(token, in: (try? element.attr($0)) ?? "") }
        }
        return (element.getAttributes()?.asList() ?? []).contains {
            $0.getKey().hasSuffix(":type") && containsToken(token, in: $0.getValue())
        }
    }

    /// Whether the ARIA `role` attribute lists `token`.
    static func hasRole(_ token: String, _ element: Element) -> Bool {
        containsToken(token, in: (try? element.attr("role")) ?? "")
    }

    /// A table of contents: EPUB 3 `toc` or DPUB-ARIA `doc-toc` on a sectioning
    /// element. A landmarks link typed `toc` only points at a TOC, so inline
    /// elements never qualify.
    static func isTableOfContents(_ element: Element) -> Bool {
        isNavigationContainer(element) && !isSupplementaryNavigation(element)
            && (hasEPUBType("toc", element) || hasRole("doc-toc", element))
    }

    /// A page list (PG05): the navigation container EPUB 3 types `page-list`
    /// (or DPUB-ARIA gives the `doc-pagelist` role), whose links name the
    /// places where the print book's pages begin.
    static func isPageList(_ element: Element) -> Bool {
        isPageList(element, typeNames: nil)
    }

    /// `isPageList(_:)` for an element of a document whose `:type` attribute
    /// names are known (see `hasEPUBType(_:_:typeNames:)`).
    static func isPageList(_ element: Element, typeNames: [String]?) -> Bool {
        isNavigationContainer(element)
            && (hasEPUBType("page-list", element, typeNames: typeNames) || hasRole("doc-pagelist", element))
    }

    /// A page break (PG05): any element EPUB 3 types `pagebreak` (or DPUB-ARIA
    /// gives the `doc-pagebreak` role) to mark where a print page begins. Its
    /// own text is usually the page's number.
    static func isPageBreak(_ element: Element) -> Bool {
        isPageBreak(element, typeNames: nil)
    }

    /// `isPageBreak(_:)` for an element of a document whose `:type` attribute
    /// names are known (see `hasEPUBType(_:_:typeNames:)`).
    static func isPageBreak(_ element: Element, typeNames: [String]?) -> Bool {
        hasEPUBType("pagebreak", element, typeNames: typeNames) || hasRole("doc-pagebreak", element)
    }

    /// Page lists and landmarks locate print pages and major regions of a book.
    /// They are navigation aids, never chapter headings or words to read aloud.
    /// `doc-landmarks` is not a registered DPUB-ARIA role; it is accepted
    /// defensively alongside the registered `doc-pagelist`.
    static func isSupplementaryNavigation(_ element: Element) -> Bool {
        isSupplementaryNavigation(element, typeNames: nil)
    }

    /// `isSupplementaryNavigation(_:)` for an element of a document whose
    /// `:type` attribute names are known (see `hasEPUBType(_:_:typeNames:)`).
    static func isSupplementaryNavigation(_ element: Element, typeNames: [String]?) -> Bool {
        guard isNavigationContainer(element) else { return false }
        return isPageList(element, typeNames: typeNames) || hasEPUBType("landmarks", element, typeNames: typeNames)
            || hasRole("doc-landmarks", element)
    }

    /// The HTML `hidden` attribute, with any value, removes an element from the
    /// rendered content flow. SwiftSoup matches attribute names case-insensitively.
    static func isHidden(_ element: Element) -> Bool {
        element.hasAttr("hidden")
    }

    /// Hidden elements, page lists, and landmarks contribute no words, headings,
    /// or navigation destinations to a book's reading text.
    static func isExcludedFromReadingFlow(_ element: Element) -> Bool {
        isHidden(element) || isSupplementaryNavigation(element)
    }

    // MARK: - One Document

    /// The reading-flow rules above, for the elements of one document, with
    /// the `hidden` check skipped wherever the document's markup cannot give
    /// an element that attribute (`mayCarryHiddenAttribute(_:)`). SwiftSoup
    /// answers the check by materializing all of an element's attributes,
    /// which once took nearly half of a typical EPUB's extraction, though
    /// few books hide anything (PERF19). Each answer is exactly the one the
    /// static rules give: the check is skipped only where it must be false.
    struct ReadingFlow {
        /// Whether an element of the document may carry `hidden`.
        let mayHideElements: Bool

        /// Whether an element of the document may be a page break (PG05):
        /// the markup spells "pagebreak", as both the `epub:type` and the
        /// `role` vocabulary do, so a document without the word needs no
        /// per-element page-break check.
        let mayHoldPageBreaks: Bool

        /// The names of the attributes of the document that end in ":type"
        /// (`PublicationSemantics.typeAttributeNames(in:)`), which its
        /// elements are asked for by name; nil when they are not known.
        let typeNames: [String]?

        /// The rules for a document parsed from the markup `source`.
        init(source: String) {
            mayHideElements = PublicationSemantics.mayCarryHiddenAttribute(source)
            mayHoldPageBreaks = PublicationSemantics.mayCarryPageBreak(source)
            typeNames = PublicationSemantics.typeAttributeNames(in: source)
        }

        /// The rules for elements whose markup is not known, which check
        /// every element.
        static let unknownSource = ReadingFlow(mayHideElements: true, mayHoldPageBreaks: true, typeNames: nil)

        /// Rules that check `hidden` only when `mayHideElements`, page
        /// breaks only when `mayHoldPageBreaks`, and the types by name when
        /// `typeNames` are known.
        private init(mayHideElements: Bool, mayHoldPageBreaks: Bool, typeNames: [String]?) {
            self.mayHideElements = mayHideElements
            self.mayHoldPageBreaks = mayHoldPageBreaks
            self.typeNames = typeNames
        }

        /// `PublicationSemantics.isHidden(_:)`, for an element of this document.
        func isHidden(_ element: Element) -> Bool {
            mayHideElements && PublicationSemantics.isHidden(element)
        }

        /// `PublicationSemantics.isExcludedFromReadingFlow(_:)`, for an
        /// element of this document.
        func excludes(_ element: Element) -> Bool {
            isHidden(element) || PublicationSemantics.isSupplementaryNavigation(element, typeNames: typeNames)
        }

        /// `PublicationSemantics.isPageBreak(_:)`, for an element of this document.
        func isPageBreak(_ element: Element) -> Bool {
            PublicationSemantics.isPageBreak(element, typeNames: typeNames)
        }
    }

    /// The names of the attributes that end in ":type" in markup written as
    /// `source`, lower case, or nil when the markup is not plain enough to
    /// say for certain (then every element is searched, as it always was).
    ///
    /// An attribute's name is spelled out in the markup: the tokenizer reads
    /// it as the characters up to white space, a slash, an equals sign, or
    /// the end of the tag, and folds only ASCII capitals to lower case. So
    /// every attribute whose name ends in ":type" has ":type" in `source`, in
    /// any mix of capitals, right after the rest of its name, and each such
    /// place is read back to the start of its name. A name is taken only when
    /// it is made of ASCII letters, numerals, and ". _ - :", follows white
    /// space, a quote, a slash, or the start, and is followed by white space,
    /// "=", ">", "/", or the end of the markup; ":type" inside a longer name
    /// ("epub:typed") is not a name ending in it. Any other place returns
    /// nil: prose with " :type", a name beyond ASCII, a tag named "x:type",
    /// the "abs:" prefix SwiftSoup reads as a request for an absolute address.
    /// No ":type" at all gives an empty list: no element has such an
    /// attribute, and none need be asked.
    static func typeAttributeNames(in source: String) -> [String]? {
        var found: [String] = []
        // The source's bytes, in place when it is stored as UTF-8.
        var contiguous = source
        contiguous.makeContiguousUTF8()
        let plain: Bool? = contiguous.utf8.withContiguousStorageIfAvailable { bytes in
            var from = 0
            while from < bytes.count {
                // The next colon from here, and the "type" that must follow.
                guard let colon = bytes[from...].firstIndex(of: UInt8(ascii: ":")) else { break }
                from = colon + 1
                let end = colon + 5
                guard end <= bytes.count,
                      bytes[colon + 1] | 0x20 == UInt8(ascii: "t"), bytes[colon + 2] | 0x20 == UInt8(ascii: "y"),
                      bytes[colon + 3] | 0x20 == UInt8(ascii: "p"), bytes[colon + 4] | 0x20 == UInt8(ascii: "e") else { continue }
                // What follows decides whether the name ends here.
                if end < bytes.count {
                    // ":type" inside a longer name is not a name ending in it.
                    if isTypeNameByte(bytes[end]) { continue }
                    guard isTypeNameEnd(bytes[end]) else { return false }
                }
                // Read back to the start of the name.
                var start = colon
                while start > 0, isTypeNameByte(bytes[start - 1]) { start -= 1 }
                guard start < colon, start == 0 || isTypeNameStart(bytes[start - 1]) else { return false }
                let name = String(decoding: bytes[start..<end], as: UTF8.self).lowercased()
                guard !name.hasPrefix("abs:") else { return false }
                if !found.contains(name) { found.append(name) }
            }
            return true
        }
        return plain == true ? found : nil
    }

    /// Whether `byte` can be part of an attribute name `typeAttributeNames`
    /// takes: an ASCII letter or numeral, or one of ". _ - :".
    private static func isTypeNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ":"):
            return true
        default:
            return false
        }
    }

    /// Whether `byte`, just after a name, ends it: white space, "=", ">", or "/".
    private static func isTypeNameEnd(_ byte: UInt8) -> Bool {
        isMarkupSpace(byte) || byte == UInt8(ascii: "=") || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
    }

    /// Whether `byte`, just before a name, can begin an attribute: white space,
    /// a quote that closed the value before it, or a slash.
    private static func isTypeNameStart(_ byte: UInt8) -> Bool {
        isMarkupSpace(byte) || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: "/")
    }

    /// Whether `byte` is a space, tab, line feed, form feed, or carriage return
    /// (the HTML tokenizer's white space; vertical tab is not among them, so
    /// it is not taken for white space here either).
    private static func isMarkupSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    /// Whether markup written as `source` can give any element the `hidden`
    /// attribute: whether it holds the letters "hidden", in any mix of
    /// capitals. An attribute's name is always spelled out in the markup:
    /// the HTML tokenizer decodes no character reference in a name and folds
    /// only ASCII capitals to lower case, and SwiftSoup compares names the
    /// same way, so markup without those letters holds no hidden element.
    static func mayCarryHiddenAttribute(_ source: String) -> Bool {
        mayContain(source, word: Array("hidden".utf8))
    }

    /// Whether markup written as `source` can hold a page-break element
    /// (PG05): whether it holds the letters "pagebreak", in any mix of
    /// capitals. Both `epub:type="pagebreak"` and `role="doc-pagebreak"`
    /// spell the word out in a token compared without regard to case.
    static func mayCarryPageBreak(_ source: String) -> Bool {
        mayContain(source, word: Array("pagebreak".utf8))
    }

    /// Whether `source` holds the lowercase ASCII letters `word`, in any mix
    /// of capitals. A failed match restarts at the byte that broke it, which
    /// is right only for a word whose first letter occurs nowhere else in it
    /// ("hidden" and "pagebreak" both qualify).
    private static func mayContain(_ source: String, word: [UInt8]) -> Bool {
        var matched = 0
        for byte in source.utf8 {
            // An ASCII capital differs from its small letter in bit 5 alone,
            // and no other byte becomes one of these small letters with it set.
            let folded = byte | 0x20
            if folded == word[matched] {
                matched += 1
                if matched == word.count { return true }
            } else {
                // No part of `word` after its first letter begins it again,
                // so a failed match can only restart at this byte.
                matched = folded == word[0] ? 1 : 0
            }
        }
        return false
    }

    /// Match one whitespace-separated token without regard to case. Every
    /// caller passes a lowercase vocabulary term.
    private static func containsToken(_ token: String, in value: String) -> Bool {
        value.lowercased().split(whereSeparator: \.isWhitespace).contains { $0 == token }
    }
}
