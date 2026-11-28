import Foundation

// MARK: - The Elements of a Document by Local Name

/// The elements of an XML document, listed by local name in one walk of its
/// tree, in document order (the November 14, 2026 import speed-up, H7).
///
/// The EPUB reader asked for the elements it wanted by XPath, mostly
/// `//*[local-name()='item']`, each of which Foundation's XQuery engine
/// answers by testing every element of the document (21 such queries, a
/// twentieth of an EPUB import, and over a fifth of one with a thousand
/// chapters). This answers each of them from the one walk: `elements(named:)`
/// is exactly what `//*[local-name()='name']` returns, the elements whose
/// `localName` is `name`, root included, in the order the document holds them.
///
/// The walk keeps its own stack rather than calling itself for every level:
/// XMLDocument reads a file nested thousands deep, and imports run on a
/// worker thread's 512 KiB stack (see `EPUBParser.takeApart(_:)`).
///
/// An index is a picture of the tree as it was when it was made: it is made
/// again after any change to the document.
struct XMLElementIndex {

    /// An element, and the local name of the element that holds it (nil for
    /// the root), for a path that asks for children of an element by name.
    private struct Entry {
        let element: XMLElement
        let parentLocalName: String?
    }

    /// Every element, by local name, in document order.
    private let entriesByLocalName: [String: [Entry]]

    /// The index of `document`'s elements.
    init(_ document: XMLDocument) {
        var entries: [String: [Entry]] = [:]
        // The elements still to visit, each with the local name of its
        // parent, last first, so that they come off the stack in document order.
        var stack: [(element: XMLElement, parentLocalName: String?)] = document.rootElement().map { [($0, nil)] } ?? []
        while let (element, parentLocalName) = stack.popLast() {
            let localName = element.localName ?? ""
            entries[localName, default: []].append(Entry(element: element, parentLocalName: parentLocalName))
            for child in (element.children ?? []).reversed() {
                if let childElement = child as? XMLElement {
                    stack.append((childElement, localName))
                }
            }
        }
        entriesByLocalName = entries
    }

    /// The elements whose local name is `name`, in document order: what
    /// `//*[local-name()='name']` returns.
    func elements(named name: String) -> [XMLElement] {
        (entriesByLocalName[name] ?? []).map(\.element)
    }

    /// The elements whose local name is `name` and whose parent's is
    /// `parentName`, in document order: what
    /// `//*[local-name()='parentName']/*[local-name()='name']` returns.
    func elements(named name: String, insideParentNamed parentName: String) -> [XMLElement] {
        (entriesByLocalName[name] ?? []).filter { $0.parentLocalName == parentName }.map(\.element)
    }
}

// MARK: - Child Elements by Local Name

extension XMLElement {
    /// The child elements whose local name is `name`, in order: what
    /// `*[local-name()='name']` returns for this element, without a query.
    func childElements(localName name: String) -> [XMLElement] {
        (children ?? []).compactMap { child in
            guard let element = child as? XMLElement, element.localName == name else { return nil }
            return element
        }
    }

    /// The first `text` element inside one of this element's `navLabel`
    /// children, as an NCX entry writes its label: what
    /// `*[local-name()='navLabel']/*[local-name()='text']` returns first.
    var firstNavLabelText: XMLElement? {
        childElements(localName: "navLabel").lazy.compactMap { $0.childElements(localName: "text").first }.first
    }
}
