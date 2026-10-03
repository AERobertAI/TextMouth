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
    static func hasEPUBType(_ token: String, _ element: Element) -> Bool {
        (element.getAttributes()?.asList() ?? []).contains {
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

    /// Page lists and landmarks locate print pages and major regions of a book.
    /// They are navigation aids, never chapter headings or words to read aloud.
    /// `doc-landmarks` is not a registered DPUB-ARIA role; it is accepted
    /// defensively alongside the registered `doc-pagelist`.
    static func isSupplementaryNavigation(_ element: Element) -> Bool {
        guard isNavigationContainer(element) else { return false }
        return hasEPUBType("page-list", element) || hasEPUBType("landmarks", element)
            || hasRole("doc-pagelist", element) || hasRole("doc-landmarks", element)
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

        /// The rules for a document parsed from the markup `source`.
        init(source: String) {
            mayHideElements = PublicationSemantics.mayCarryHiddenAttribute(source)
        }

        /// The rules for elements whose markup is not known, which check
        /// every element.
        static let unknownSource = ReadingFlow(mayHideElements: true)

        /// Rules that check `hidden` only when `mayHideElements`.
        private init(mayHideElements: Bool) {
            self.mayHideElements = mayHideElements
        }

        /// `PublicationSemantics.isHidden(_:)`, for an element of this document.
        func isHidden(_ element: Element) -> Bool {
            mayHideElements && PublicationSemantics.isHidden(element)
        }

        /// `PublicationSemantics.isExcludedFromReadingFlow(_:)`, for an
        /// element of this document.
        func excludes(_ element: Element) -> Bool {
            isHidden(element) || PublicationSemantics.isSupplementaryNavigation(element)
        }
    }

    /// Whether markup written as `source` can give any element the `hidden`
    /// attribute: whether it holds the letters "hidden", in any mix of
    /// capitals. An attribute's name is always spelled out in the markup:
    /// the HTML tokenizer decodes no character reference in a name and folds
    /// only ASCII capitals to lower case, and SwiftSoup compares names the
    /// same way, so markup without those letters holds no hidden element.
    static func mayCarryHiddenAttribute(_ source: String) -> Bool {
        let name = Array("hidden".utf8)
        var matched = 0
        for byte in source.utf8 {
            // An ASCII capital differs from its small letter in bit 5 alone,
            // and no other byte becomes one of these small letters with it set.
            let folded = byte | 0x20
            if folded == name[matched] {
                matched += 1
                if matched == name.count { return true }
            } else {
                // No part of "hidden" after its first letter begins it again,
                // so a failed match can only restart at this byte.
                matched = folded == name[0] ? 1 : 0
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
