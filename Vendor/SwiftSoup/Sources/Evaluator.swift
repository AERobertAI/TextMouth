//
//  Evaluator.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 22/10/16.
//

import Foundation

private enum AsciiSearch {
    static func lower(_ byte: UInt8) -> UInt8 {
        if byte >= 65 && byte <= 90 {
            return byte &+ 32
        }
        return byte
    }

    static func containsCaseInsensitive(_ haystack: ArraySlice<UInt8>, needleLower: [UInt8]) -> Bool {
        let needleCount = needleLower.count
        if needleCount == 0 {
            return true
        }
        let hayCount = haystack.count
        if hayCount < needleCount {
            return false
        }
        let lastStart = haystack.endIndex - needleCount
        var i = haystack.startIndex
        while i <= lastStart {
            if lower(haystack[i]) == needleLower[0] {
                var j = 1
                while j < needleCount {
                    if lower(haystack[i + j]) != needleLower[j] {
                        break
                    }
                    j += 1
                }
                if j == needleCount {
                    return true
                }
            }
            i += 1
        }
        return false
    }
}

/// Evaluates that an element matches the selector.
class Evaluator: @unchecked Sendable {
    public init () {}

    /**
     Test if the element meets the evaluator's requirements.
     
     - parameter root:    Root of the matching subtree
     - parameter element: tested element
     - returns: Returns `true` if the requirements are met or `false` otherwise.
     */
    func matches(_ root: Element, _ element: Element)throws->Bool {
        preconditionFailure("self method must be overridden")
    }

    func toString() -> String {
        preconditionFailure("self method must be overridden")
    }

    /**
     * Evaluator for tag name
     */
    public class Tag: Evaluator, @unchecked Sendable {
        private let tagName: [UInt8]
        let tagNameNormal: [UInt8]
        private let tagId: Token.Tag.TagId

        public init(_ tagName: String) {
            let utf8TagName = tagName.utf8Array
            self.tagName = utf8TagName
            self.tagNameNormal = utf8TagName.lowercased()
            self.tagId = Token.Tag.tagIdForBytes(self.tagNameNormal) ?? .none
        }
        
        public init(_ tagName: [UInt8]) {
            self.tagName = tagName
            self.tagNameNormal = tagName.lowercased()
            self.tagId = Token.Tag.tagIdForBytes(self.tagNameNormal) ?? .none
        }

        override func matches(_ root: Element, _ element: Element) throws -> Bool {
            if tagId != .none {
                let elTagId = element._tag.tagId
                if elTagId != .none {
                    return elTagId == tagId
                }
            }
            return element.tagNameNormalUTF8() == tagNameNormal
        }

        override func toString() -> String {
            return String(decoding: tagName, as: UTF8.self)
        }
    }

    /**
     * Evaluator for tag name that ends with the given suffix.
     */
    final class TagEndsWith: Evaluator, @unchecked Sendable {
        private let tagName: String

        public init(_ tagName: String) {
            self.tagName = tagName
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return (element.tagName().hasSuffix(tagName))
        }

        override func toString() -> String {
            return String(tagName)
        }
    }

    /**
     * Evaluator for element id
     */
    final class Id: Evaluator, @unchecked Sendable {
        let id: String
        let idBytes: [UInt8]

        public init(_ id: String) {
            self.id = id
            self.idBytes = id.utf8Array
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return idBytes == element.idUTF8()
        }

        override func toString() -> String {
            return "#\(id)"
        }

    }

    /**
     * Evaluator for element class
     */
    final class Class: Evaluator, @unchecked Sendable {
        let className: String
        let classNameBytes: [UInt8]

        public init(_ className: String) {
            self.className = className
            self.classNameBytes = className.utf8Array
        }

        override func matches(_ root: Element, _ element: Element) -> Bool {
            return element.hasClass(classNameBytes)
        }

        override func toString() -> String {
            return ".\(className)"
        }

    }

    /**
     * Evaluator for attribute name matching
     */
    public final class Attribute: Evaluator, @unchecked Sendable {
        let key: String
        let keyBytes: [UInt8]

        public init(_ key: String) {
            self.key = key
            self.keyBytes = key.trim().lowercased().utf8Array
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return element.hasAttr(keyBytes)
        }

        override func toString() -> String {
            return "[\(key)]"
        }

    }

    /**
     * Evaluator for attribute name prefix matching
     */
    final class AttributeStarting: Evaluator, @unchecked Sendable {
        private let keyPrefix: [UInt8]

        public init(_ keyPrefix: [UInt8]) throws {
            try Validate.notEmpty(string: keyPrefix)
            self.keyPrefix = keyPrefix.lowercased()
        }

        override func matches(_ root: Element, _ element: Element) throws -> Bool {
            if let values = element.getAttributes() {
                for attribute in values {
                    let key = attribute.keySlice
                    if key.count < keyPrefix.count { continue }
                    var matches = true
                    var i = 0
                    while i < keyPrefix.count {
                        let b = key[i]
                        let lower = (b >= 65 && b <= 90) ? (b &+ 32) : b
                        if lower != keyPrefix[i] {
                            matches = false
                            break
                        }
                        i &+= 1
                    }
                    if matches {
                        return true
                    }
                }
            }
            return false
        }

        override func toString() -> String {
            return "[^\(String(decoding: keyPrefix, as: UTF8.self))]"
        }

    }

    /**
     * Evaluator for attribute name/value matching
     */
    final class AttributeWithValue: AttributeKeyPair, @unchecked Sendable {
        public override init(_ key: String, _ value: String)throws {
            try super.init(key, value)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return false }
                let needsTrim = (slice.first?.isWhitespace ?? false) || (slice.last?.isWhitespace ?? false)
                let candidate = needsTrim ? slice.trim() : slice
                return StringUtil.equalsIgnoreCase(valueBytes, candidate)
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return false
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return false }
            let needsTrim = (bytes.first?.isWhitespace ?? false) || (bytes.last?.isWhitespace ?? false)
            let candidate = needsTrim ? bytes.trim() : bytes
            return valueBytes.equalsIgnoreCase(string: candidate)
        }

        override func toString() -> String {
            return "[\(key)=\(value)]"
        }

    }

    /**
     * Evaluator for attribute name != value matching
     */
    final class AttributeWithValueNot: AttributeKeyPair, @unchecked Sendable {
        public override init(_ key: String, _ value: String)throws {
            try super.init(key, value)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return true }
                return !StringUtil.equalsIgnoreCase(valueBytes, slice)
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return true
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return true }
            return !valueBytes.equalsIgnoreCase(string: bytes)
        }

        override func toString() -> String {
            return "[\(key)!=\(value)]"
        }

    }

    /**
     * Evaluator for attribute name/value matching (value prefix)
     */
    final class AttributeWithValueStarting: AttributeKeyPair, @unchecked Sendable {
        public override init(_ key: String, _ value: String)throws {
            try super.init(key, value)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return false }
                if StringUtil.isAscii(slice),
                   StringUtil.isAscii(valueBytes) {
                    return StringUtil.hasPrefixLowercaseAscii(slice, valueBytes)
                }
                let string = slice.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                return string.lowercased().hasPrefix(value)
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return false
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return false }
            if StringUtil.isAscii(bytes),
               StringUtil.isAscii(valueBytes) {
                return StringUtil.hasPrefixLowercaseAscii(bytes, valueBytes)
            }
            return String(decoding: bytes, as: UTF8.self).lowercased().hasPrefix(value)
        }

        override func toString() -> String {
            return "[\(key)^=\(value)]"
        }

    }

    /**
     * Evaluator for attribute name/value matching (value ending)
     */
    final class AttributeWithValueEnding: AttributeKeyPair, @unchecked Sendable {
        public override init(_ key: String, _ value: String)throws {
            try super.init(key, value)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return false }
                if StringUtil.isAscii(slice),
                   StringUtil.isAscii(valueBytes) {
                    return StringUtil.hasSuffixLowercaseAscii(slice, valueBytes)
                }
                let string = slice.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                return string.lowercased().hasSuffix(value)
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return false
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return false }
            if StringUtil.isAscii(bytes),
               StringUtil.isAscii(valueBytes) {
                return StringUtil.hasSuffixLowercaseAscii(bytes, valueBytes)
            }
            return String(decoding: bytes, as: UTF8.self).lowercased().hasSuffix(value)
        }

        override func toString() -> String {
            return "[\(key)$=\(value)]"
        }

    }

    /**
     * Evaluator for attribute name/value matching (value containing)
     */
    final class AttributeWithValueContaining: AttributeKeyPair, @unchecked Sendable {
        public override init(_ key: String, _ value: String)throws {
            try super.init(key, value)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return false }
                if StringUtil.isAscii(slice),
                   StringUtil.isAscii(valueBytes) {
                    return StringUtil.containsLowercaseAscii(slice, valueBytes)
                }
                let string = slice.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                return string.lowercased().contains(value)
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return false
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return false }
            if StringUtil.isAscii(bytes),
               StringUtil.isAscii(valueBytes) {
                return StringUtil.containsLowercaseAscii(bytes, valueBytes)
            }
            return String(decoding: bytes, as: UTF8.self).lowercased().contains(value)
        }

        override func toString() -> String {
            return "[\(key)*=\(value)]"
        }

    }

    /**
     * Evaluator for attribute name/value matching (value regex matching)
     */
    final class AttributeWithValueMatching: Evaluator, @unchecked Sendable {
        let key: String
        let keyBytes: [UInt8]
        let pattern: Pattern

        public init(_ key: String, _ pattern: Pattern) {
            self.key = key.trim().lowercased()
            self.keyBytes = self.key.utf8Array
            self.pattern = pattern
            super.init()
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let slice = element.attrSlice(keyBytes) {
                if slice.isEmpty { return false }
                let string = slice.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                return pattern.matcher(in: string).find()
            }
            if !Element.isAbsAttributeKey(keyBytes) {
                return false
            }
            let bytes = try element.attr(keyBytes)
            if bytes.isEmpty { return false }
            let string = String(decoding: bytes, as: UTF8.self)
            return pattern.matcher(in: string).find()
        }

        override func toString() -> String {
            return "[\(key)~=\(pattern.toString())]"
        }

    }

    /**
     * Abstract evaluator for attribute name/value matching
     */
    class AttributeKeyPair: Evaluator, @unchecked Sendable {
        let key: String
        let value: String
        let keyBytes: [UInt8]
        let valueBytes: [UInt8]

        public init(_ key: String, _ value2: String)throws {
            var value2 = value2
            try Validate.notEmpty(string: key)
            try Validate.notEmpty(string: value2)

            self.key = key.trim().lowercased()
            if value2.startsWith("\"") && value2.hasSuffix("\"") || value2.startsWith("'") && value2.hasSuffix("'") {
                value2 = value2.substring(1, value2.count-2)
            }
            self.value = value2.trim().lowercased()
            self.keyBytes = self.key.utf8Array
            self.valueBytes = self.value.utf8Array
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            preconditionFailure("self method must be overridden")
        }
    }

    /**
     * Evaluator for any / all element matching
     */
    final class AllElements: Evaluator, @unchecked Sendable {

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return true
        }

        override func toString() -> String {
            return "*"
        }
    }

    /**
     * Evaluator for matching by sibling index number (`e < idx`).
     */
    final class IndexLessThan: IndexEvaluator, @unchecked Sendable {
        public override init(_ index: Int) {
            super.init(index)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return try element.elementSiblingIndex() < index
        }

        override func toString() -> String {
            return ":lt(\(index))"
        }

    }

    /**
     * Evaluator for matching by sibling index number (`e > idx`).
     */
    final class IndexGreaterThan: IndexEvaluator, @unchecked Sendable {
        public override init(_ index: Int) {
            super.init(index)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return try element.elementSiblingIndex() > index
        }

        override func toString() -> String {
            return ":gt(\(index))"
        }

    }

    /**
     * Evaluator for matching by sibling index number (`e == idx`)
     */
    final class IndexEquals: IndexEvaluator, @unchecked Sendable {
        public override init(_ index: Int) {
            super.init(index)
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return try element.elementSiblingIndex() == index
        }

        override func toString() -> String {
            return ":eq(\(index))"
        }

    }

    /**
     * Evaluator for matching the last sibling (CSS `:last-child`)
     */
    final class IsLastChild: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let parent = element.parent(), !(parent is Document), element !== root {
                return (try element.nextElementSibling()) == nil
            }
            return false
        }

        override func toString() -> String {
            return ":last-child"
        }
    }

    final class IsFirstOfType: IsNthOfType, @unchecked Sendable {
        public init() {
            super.init(0, 1)
        }
        override func toString() -> String {
            return ":first-of-type"
        }
    }

    final class IsLastOfType: IsNthLastOfType, @unchecked Sendable {
        public init() {
            super.init(0, 1)
        }
        override func toString() -> String {
            return ":last-of-type"
        }
    }

    class CssNthEvaluator: Evaluator, @unchecked Sendable {
        let a: Int
        let b: Int

        public init(_ a: Int, _ b: Int) {
            self.a = a
            self.b = b
        }
        public init(_ b: Int) {
            self.a = 0
            self.b = b
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let p: Element? = element.parent()
            if (p == nil || (((p as? Document) != nil))) {return false}

            let pos: Int = try calculatePosition(root, element)
            if (a == 0) {return pos == b}

            return (pos-b)*a >= 0 && (pos-b)%a==0
        }

        override func toString() -> String {
            if (a == 0) {
                return ":\(getPseudoClass())(\(b))"
            }
            if (b == 0) {
                return ":\(getPseudoClass())(\(a))"
            }
            return ":\(getPseudoClass())(\(a)\(b))"
        }

        func getPseudoClass() -> String {
            preconditionFailure("self method must be overridden")
        }
        func calculatePosition(_ root: Element, _ element: Element)throws->Int {
            preconditionFailure("self method must be overridden")
        }
    }

    /**
     CSS-compatible Evaluator for `:eq` (CSS `:nth-child`)
     
     - seealso: ``IndexEquals``
     */
    final class IsNthChild: CssNthEvaluator, @unchecked Sendable {

        public override init(_ a: Int, _ b: Int) {
            super.init(a, b)
        }

        override func calculatePosition(_ root: Element, _ element: Element)throws->Int {
            return try element.elementSiblingIndex()+1
        }

        override func getPseudoClass() -> String {
            return "nth-child"
        }
    }

    /**
     CSS pseudo class `:nth-last-child`
     
     - seealso: ``IndexEquals``
     */
    final class IsNthLastChild: CssNthEvaluator, @unchecked Sendable {
        public override init(_ a: Int, _ b: Int) {
            super.init(a, b)
        }

        override func calculatePosition(_ root: Element, _ element: Element)throws->Int {
            var i = 0

            if let l = element.parent() {
                i = l.children().array().count
            }
            return i - (try element.elementSiblingIndex())
        }

        override func getPseudoClass() -> String {
            return "nth-last-child"
        }
    }

    /**
     CSS pseudo class `:nth-of-type`
     */
    class IsNthOfType: CssNthEvaluator, @unchecked Sendable {
        public override init(_ a: Int, _ b: Int) {
            super.init(a, b)
        }

        override func calculatePosition(_ root: Element, _ element: Element) -> Int {
            var pos = 0
            let family: Elements? = element.parent()?.children()
            if let array = family?.array() {
                for el in array {
                    if (el.tag() == element.tag()) {pos+=1}
                    if (el === element) {break}
                }
            }

            return pos
        }

        override func getPseudoClass() -> String {
            return "nth-of-type"
        }
    }

    class IsNthLastOfType: CssNthEvaluator, @unchecked Sendable {

        public override init(_ a: Int, _ b: Int) {
            super.init(a, b)
        }

        override func calculatePosition(_ root: Element, _ element: Element)throws->Int {
            var pos = 0
            if let family = element.parent()?.children() {
                let x = try element.elementSiblingIndex()
                for i in x..<family.array().count {
                    if (family.get(i).tag() == element.tag()) {
                        pos+=1
                    }
                }
            }

            return pos
        }

        override func getPseudoClass() -> String {
            return "nth-last-of-type"
        }
    }

    /**
     * Evaluator for matching the first sibling (CSS `:first-child`)
     */
    final class IsFirstChild: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let p = element.parent()
            if element !== root, p != nil, !(p is Document) {
                return (try element.elementSiblingIndex()) == 0
            }
            return false
        }

        override func toString() -> String {
            return ":first-child"
        }
    }

    /**
     CSS3 pseudo-class `:root`
     
     - seealso: [`:root` selector](https://www.w3.org/TR/selectors/#root-pseudo)
     */
    final class IsRoot: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let r: Element = ((root as? Document) != nil) ? root.child(0) : root
            return element === r
        }
        override func toString() -> String {
            return ":root"
        }
    }

    final class IsOnlyChild: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let p = element.parent()
            return p != nil && !((p as? Document) != nil) && element.siblingElements().isEmpty()
        }
        override func toString() -> String {
            return ":only-child"
        }
    }

    final class IsOnlyOfType: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let p = element.parent()
            if (p == nil || (p as? Document) != nil) {return false}

            var pos = 0
            if let family = p?.children().array() {
                for  el in family {
                    if (el.tag() == element.tag()) {pos+=1}
                }
            }
            return pos == 1
        }

        override func toString() -> String {
            return ":only-of-type"
        }
    }

    final class IsEmpty: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let family: Array<Node> = element.getChildNodes()
            for n in family {
                if (!((n as? Comment) != nil || (n as? XmlDeclaration) != nil || (n as? DocumentType) != nil)) {return false}
            }
            return true
        }

        override func toString() -> String {
            return ":empty"
        }
    }

    /**
     * Abstract evaluator for sibling index matching
     */
    class IndexEvaluator: Evaluator, @unchecked Sendable {
        let index: Int

        public init(_ index: Int) {
            self.index = index
        }
    }

    /**
     * Evaluator for matching Element (and its descendants) text
     */
    final class ContainsText: Evaluator, @unchecked Sendable {
        private let searchText: String
        private let searchTextLowerUTF8: [UInt8]?

        public init(_ searchText: String) {
            let lowered = searchText.lowercased()
            self.searchText = lowered
            let utf8 = [UInt8](lowered.utf8)
            if utf8.allSatisfy({ $0 < TokeniserStateVars.asciiUpperLimitByte }) {
                self.searchTextLowerUTF8 = utf8
            } else {
                self.searchTextLowerUTF8 = nil
            }
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let needle = searchTextLowerUTF8 {
                if let slice = element.textUTF8ByteSlice(trimAndNormaliseWhitespace: true) {
                    return StringUtil.containsLowercaseAscii(slice, needle)
                }
                return element.containsNormalizedTextASCII(needle)
            }
            return (try element.text().lowercased().contains(searchText))
        }

        override func toString() -> String {
            return ":contains(\(searchText)"
        }
    }

    /**
     * Evaluator for matching Element's own text
     */
    final class ContainsOwnText: Evaluator, @unchecked Sendable {
        private let searchText: String
        private let searchTextLowerUTF8: [UInt8]?

        public init(_ searchText: String) {
            let lowered = searchText.lowercased()
            self.searchText = lowered
            let utf8 = [UInt8](lowered.utf8)
            if utf8.allSatisfy({ $0 < TokeniserStateVars.asciiUpperLimitByte }) {
                self.searchTextLowerUTF8 = utf8
            } else {
                self.searchTextLowerUTF8 = nil
            }
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            if let needle = searchTextLowerUTF8 {
                if let slice = element.textUTF8ByteSlice(trimAndNormaliseWhitespace: true) {
                    return StringUtil.containsLowercaseAscii(slice, needle)
                }
                return element.containsOwnTextASCII(needle)
            }
            return (element.ownText().lowercased().contains(searchText))
        }

        override func toString() -> String {
            return ":containsOwn(\(searchText)"
        }
    }

    /**
     * Evaluator for matching Element (and its descendants) data. The contents of script and style
     * elements, and comment nodes (etc) are considered data nodes, not text nodes.
     * The search is case insensitive and not whitespace normalized.
     */
    final class ContainsData: Evaluator, @unchecked Sendable {
        private let searchText: String

        public init(_ searchText: String) {
            self.searchText = searchText.lowercased()
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            return element.data().lowercased().contains(searchText)
        }

        override func toString() -> String {
            return ":containsData(\(searchText)"
        }
    }

    /**
     * Evaluator for matching Element (and its descendants) text with regex
     */
    final class Matches: Evaluator, @unchecked Sendable {
        private let pattern: Pattern

        public init(_ pattern: Pattern) {
            self.pattern = pattern
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let m = try pattern.matcher(in: element.text())
            return m.find()
        }

        override func toString() -> String {
            return ":matches(\(pattern)"
        }
    }

    /**
     * Evaluator for matching Element's own text with regex
     */
    final class MatchesOwn: Evaluator, @unchecked Sendable {
        private let pattern: Pattern

        public init(_ pattern: Pattern) {
            self.pattern = pattern
        }

        override func matches(_ root: Element, _ element: Element)throws->Bool {
            let m = pattern.matcher(in: element.ownText())
            return m.find()
        }

        override func toString() -> String {
            return ":matchesOwn(\(pattern.toString())"
        }
    }
}
