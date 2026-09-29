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

    /// Match one whitespace-separated token without regard to case. Every
    /// caller passes a lowercase vocabulary term.
    private static func containsToken(_ token: String, in value: String) -> Bool {
        value.lowercased().split(whereSeparator: \.isWhitespace).contains { $0 == token }
    }
}
