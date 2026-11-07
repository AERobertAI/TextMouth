import Foundation

// MARK: - The XPath Subset

/// The part of XPath 1.0 the EPUB, feed, and OPML readers use on a portable
/// XML tree (`PortableXMLNode.nodes(forXPath:)`).
///
/// An expression is a path of steps separated by `/`, optionally starting
/// with `//`. Every step is `*` followed by any number of predicates:
///
/// - `[local-name()='x']`: the element's name without its prefix is `x`;
/// - `[@a]`: the element has an unprefixed attribute `a`;
/// - `[@a='v']`: the element has an unprefixed attribute `a` whose value is `v`.
///
/// Quotes in a predicate may be single or double. So
/// `//*[local-name()='meta'][@refines][@property='role']` is understood,
/// and so is `*[local-name()='navLabel']/*[local-name()='text']`.
///
/// - A path that starts with `//` selects at any depth, and is evaluated
///   from a document: from an element it throws, since the portable tree
///   keeps no link from a node to its document.
/// - Any other path starts with the children of the node it is evaluated from.
///
/// Anything else (a name test, an axis, a function, a position, `|`) is
/// refused with `PortableXMLError.unsupportedXPath`, so that an expression
/// the tree does not understand can never read as "matches nothing".
struct PortableXMLPath {
    /// One condition an element must meet.
    enum Predicate: Equatable {
        /// `local-name()='x'`.
        case localName(String)
        /// `@a`, or `@a='v'` when a value is given.
        case attribute(name: String, value: String?)
    }

    /// A step: the conditions of one element along the path (`*` plus its predicates).
    struct Step: Equatable {
        var predicates: [Predicate] = []

        /// Whether `element` meets every predicate of the step.
        func matches(_ node: PortableXMLNode) -> Bool {
            guard let element = node as? PortableXMLElement else { return false }
            return predicates.allSatisfy { predicate in
                switch predicate {
                case let .localName(name):
                    return element.localName == name
                case let .attribute(name, value):
                    // An unprefixed attribute only: `@a` never names `x:a`.
                    guard let attribute = element.attributeNodes.first(where: { $0.name == name }) else {
                        return false
                    }
                    return value.map { attribute.content == $0 } ?? true
                }
            }
        }
    }

    /// Whether the path started with `//`.
    let isAbsolute: Bool
    /// The steps, first to last; never empty.
    let steps: [Step]
    /// The expression as given, for the error.
    private let expression: String

    // MARK: Parsing

    /// Read `expression`.
    /// - Throws: `PortableXMLError.unsupportedXPath` when it is outside the subset.
    init(_ expression: String) throws {
        self.expression = expression
        var scanner = PathScanner(characters: Array(expression))
        let absolute = scanner.consume("//")
        var steps: [Step] = []
        repeat {
            steps.append(try Self.step(from: &scanner, expression: expression))
        } while scanner.consume("/")
        guard scanner.isAtEnd else { throw PortableXMLError.unsupportedXPath(expression) }
        self.isAbsolute = absolute
        self.steps = steps
    }

    /// A cursor over the characters of an expression.
    private struct PathScanner {
        let characters: [Character]
        var position = 0

        /// Whether every character has been read.
        var isAtEnd: Bool { position >= characters.count }

        /// Reads `text` if it comes next, and says whether it did.
        mutating func consume(_ text: String) -> Bool {
            let wanted = Array(text)
            guard position + wanted.count <= characters.count,
                  Array(characters[position..<position + wanted.count]) == wanted else { return false }
            position += wanted.count
            return true
        }

        /// Reads up to `terminator` (not including it) and then it, or nil
        /// when `terminator` never comes.
        mutating func read(upTo terminator: Character) -> String? {
            guard let end = characters[position...].firstIndex(of: terminator) else { return nil }
            let text = String(characters[position..<end])
            position = end + 1
            return text
        }

        /// Reads a quoted string, single or double quotes, and returns what is inside.
        mutating func readQuoted() -> String? {
            guard position < characters.count, characters[position] == "'" || characters[position] == "\"" else {
                return nil
            }
            let quote = characters[position]
            position += 1
            return read(upTo: quote)
        }

        /// Reads an unprefixed attribute name: letters, digits, `_`, `-`, and `.`.
        mutating func readName() -> String? {
            let start = position
            while position < characters.count,
                  characters[position].isLetter || characters[position].isNumber
                    || "_-.".contains(characters[position]) {
                position += 1
            }
            return position > start ? String(characters[start..<position]) : nil
        }
    }

    /// Reads one step from `scanner`: `*` and its predicates.
    private static func step(from scanner: inout PathScanner, expression: String) throws -> Step {
        let unsupported = PortableXMLError.unsupportedXPath(expression)
        guard scanner.consume("*") else { throw unsupported }
        var step = Step()
        while scanner.consume("[") {
            if scanner.consume("local-name()=") {
                guard let name = scanner.readQuoted(), scanner.consume("]") else { throw unsupported }
                step.predicates.append(.localName(name))
            } else if scanner.consume("@") {
                guard let name = scanner.readName() else { throw unsupported }
                if scanner.consume("]") {
                    step.predicates.append(.attribute(name: name, value: nil))
                } else if scanner.consume("="), let value = scanner.readQuoted(), scanner.consume("]") {
                    step.predicates.append(.attribute(name: name, value: value))
                } else {
                    throw unsupported
                }
            } else {
                throw unsupported
            }
        }
        return step
    }

    // MARK: Evaluating

    /// The nodes the path selects from `context`, in document order.
    /// - Throws: `PortableXMLError.unsupportedXPath` for a `//` path
    ///   evaluated from anything but a document.
    func evaluate(from context: PortableXMLNode) throws -> [PortableXMLNode] {
        if isAbsolute {
            guard context.kind == .document else { throw PortableXMLError.unsupportedXPath(expression) }
            return descendants(of: context)
        }
        // Each step moves from the nodes found so far to their children
        // that meet the step. Children of distinct nodes of one level are in
        // distinct subtrees, so the order stays the document's.
        var found = [context]
        for step in steps {
            found = found.flatMap { $0.childNodes.filter(step.matches) }
        }
        return found
    }

    /// The elements below `document` that the whole path selects, wherever
    /// the first step lies: the last step must match the element, the one
    /// before it its parent, and so on up the steps. Found with one walk
    /// that keeps the open elements, which also puts the results in document
    /// order, and with an explicit stack in place of recursion.
    private func descendants(of document: PortableXMLNode) -> [PortableXMLNode] {
        var selected: [PortableXMLNode] = []
        // The nodes open in the walk, from the document down, and the index
        // of the next child each one is to visit.
        var open: [PortableXMLNode] = [document]
        var nextChild: [Int] = [0]
        while let current = open.last {
            let index = nextChild[nextChild.count - 1]
            guard index < current.childNodes.count else {
                open.removeLast()
                nextChild.removeLast()
                continue
            }
            nextChild[nextChild.count - 1] += 1
            let child = current.childNodes[index]
            guard child.kind == .element else { continue }
            open.append(child)
            nextChild.append(0)
            if matchesChain(endingAt: open) { selected.append(child) }
        }
        return selected
    }

    /// Whether the last steps of the path match the last elements of `open`
    /// (the document first, then the elements down to the candidate): the
    /// candidate meets the last step, its parent the step before.
    private func matchesChain(endingAt open: [PortableXMLNode]) -> Bool {
        // `open[0]` is the document, which no step can match.
        guard open.count - 1 >= steps.count else { return false }
        return steps.reversed().enumerated().allSatisfy { offset, step in
            step.matches(open[open.count - 1 - offset])
        }
    }
}
