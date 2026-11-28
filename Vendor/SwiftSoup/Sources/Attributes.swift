//
//  Attributes.swift
//  SwifSoup
//
//  Created by Nabil Chatbi on 29/09/16.
//

import Foundation

/**
 The attributes of an Element.
 
 Attributes are treated as a map: there can be only one value associated with an attribute key/name.
 
 Attribute name and value comparisons are **case sensitive**. By default for HTML, attribute names are
 normalized to lower-case on parsing. That means you should use lower-case strings when referring to attributes by
 name.
 */
struct AttributeMutation {
    let keep: Bool
    let newValue: [UInt8]?
    
    public init(keep: Bool, newValue: [UInt8]? = nil) {
        self.keep = keep
        self.newValue = newValue
    }
}


public final class Attributes: NSCopying {
    static let dataPrefix: [UInt8] = "data-".utf8Array

    internal enum PendingAttrValue {
        case none
        case empty
        case slice(ByteSlice)
        case slices([ByteSlice], Int)
        case bytes([UInt8])
    }

    internal struct PendingAttribute {
        var nameSlice: ByteSlice?
        var nameBytes: [UInt8]?
        var hasUppercase: Bool
        var value: PendingAttrValue
    }

    static let disableLowercasedKeyIndex: Bool = false

    static let keyIndexThreshold: Int = 4
    
    
    // Stored by lowercased key, but key case is checked against the copy inside
    // the Attribute on retrieval.
    var attributes: [Attribute] = [] {
        didSet {
            ownerElement?.markClassQueryIndexDirty()
            ownerElement?.markIdQueryIndexDirty()
            ownerElement?.markAttributeQueryIndexDirty()
            ownerElement?.markAttributeValueQueryIndexDirty()
            ownerElement?.markSourceDirty()
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
        }
    }
    
    /// Set of lower‑cased UTF‑8 keys for fast O(1) ignore‑case look‑ups
    internal var lowercasedKeysCache: Set<ByteSlice>? = nil

    internal var lowercasedKeyIndex: [ByteSlice: Int]? = nil

    internal var lowercasedKeyIndexDirty: Bool = true
    
    internal var hasUppercaseKeys: Bool = false

    internal var keyIndex: [ByteSlice: Int]? = nil

    internal var keyIndexDirty: Bool = true

    internal var pendingAttributes: [PendingAttribute]? = nil
    
    internal var pendingAttributesCount: Int = 0
    
    // TODO: Delegate would be cleaner...
    weak var ownerElement: SwiftSoup.Element?
    
    public init() {
        attributes.reserveCapacity(16)
    }

    /// Materializes a deferred attribute, throwing if the key fails validation (e.g. an
    /// empty-after-trim key). Callers invoke this via `try?` and drop anything that fails,
    /// matching jsoup — never trapping. See #392.
    internal func makeMaterializedAttribute(keySlice: ByteSlice, value: PendingAttrValue) throws -> Attribute {
        switch value {
        case .none:
            return try BooleanAttribute(keySlice: keySlice)
        case .empty:
            return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.empty)
        case .slice(let slice):
            return try Attribute(keySlice: keySlice, valueSlice: slice)
        case .slices(let slices, _):
            guard let first = slices.first else {
                return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.empty)
            }
            let attribute = try Attribute(keySlice: keySlice, valueSlice: first)
            for slice in slices.dropFirst() {
                attribute.appendValueSlice(slice)
            }
            return attribute
        case .bytes(let bytes):
            return try Attribute(keySlice: keySlice, valueSlice: ByteSlice.fromArray(bytes))
        }
    }

    internal func appendPending(_ pending: PendingAttribute) {
        if !attributes.isEmpty {
            // If materialized already, fall back to regular put.
            let keySlice: ByteSlice
            if let nameBytes = pending.nameBytes {
                keySlice = ByteSlice.fromArray(nameBytes).trim()
            } else if let nameSlice = pending.nameSlice {
                keySlice = nameSlice.trim()
            } else {
                return
            }
            // Drop malformed attributes (e.g. an empty-after-trim key) rather than
            // trapping; jsoup does the same. See #392.
            guard let attribute = try? makeMaterializedAttribute(keySlice: keySlice, value: pending.value) else { return }
            putMaterialized(attribute)
            return
        }

        if pendingAttributes == nil {
            pendingAttributes = []
            pendingAttributes!.reserveCapacity(16)
            pendingAttributes!.append(pending)
            pendingAttributesCount = 1
        } else {
            pendingAttributes!.append(pending)
            pendingAttributesCount &+= 1
        }
        if !hasUppercaseKeys && pending.hasUppercase {
            hasUppercaseKeys = true
        }
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()
        ownerElement?.markClassQueryIndexDirty()
        ownerElement?.markIdQueryIndexDirty()
        ownerElement?.markAttributeQueryIndexDirty()
        ownerElement?.markAttributeValueQueryIndexDirty()
        ownerElement?.markSourceDirty()
    }

    internal func ensureMaterialized() {
        guard let pending = pendingAttributes, !pending.isEmpty else { return }
        DebugTrace.log("Attributes.ensureMaterialized: pending=\(pending.count)")
        pendingAttributesCount = 0
        let shouldIndex = shouldBuildKeyIndex()
        var localIndex: [ByteSlice: Int]? = nil
        if shouldIndex {
            if !keyIndexDirty, let existing = keyIndex {
                localIndex = existing
            } else {
                localIndex = [:]
                localIndex?.reserveCapacity(attributes.count + pending.count)
                for (idx, attr) in attributes.enumerated() {
                    localIndex?[attr.keySlice] = idx
                }
            }
        }
        var touchedClass = false
        var touchedId = false
        attributes.reserveCapacity(attributes.count + pending.count)
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                DebugTrace.log("Attributes.ensureMaterialized: nameBytes=\(String(decoding: nameBytes, as: UTF8.self))")
            } else if let nameSlice = pendingAttr.nameSlice {
                DebugTrace.log("Attributes.ensureMaterialized: nameSlice count=\(nameSlice.count)")
            } else {
                DebugTrace.log("Attributes.ensureMaterialized: missing name")
            }
            let keySlice: ByteSlice
            if let nameBytes = pendingAttr.nameBytes {
                keySlice = ByteSlice.fromArray(nameBytes).trim()
            } else if let nameSlice = pendingAttr.nameSlice {
                keySlice = nameSlice.trim()
            } else {
                continue
            }
            // Drop malformed attributes (e.g. an empty-after-trim key) rather than
            // trapping; jsoup does the same. This is the path #392 hits via
            // getIgnoreCase during select()'s query-index rebuild.
            guard let attribute = try? makeMaterializedAttribute(keySlice: keySlice, value: pendingAttr.value) else { continue }
            let keyForIndex = attribute.keySlice
            if Attributes.containsAsciiUppercase(keyForIndex) {
                hasUppercaseKeys = true
            }
            let normalizedKey = Attributes.containsAsciiUppercase(keyForIndex) ? keyForIndex.lowercased() : keyForIndex
            if equalsSlice(normalizedKey, UTF8Arrays.class_) {
                touchedClass = true
            }
            if equalsSlice(normalizedKey, SwiftSoup.Element.idString) {
                touchedId = true
            }
            if let index = localIndex?[keyForIndex] {
                attributes[index] = attribute
            } else if shouldIndex {
                localIndex?[keyForIndex] = attributes.count
                attributes.append(attribute)
            } else if let index = attributes.firstIndex(where: { $0.keySlice == keyForIndex }) {
                attributes[index] = attribute
            } else {
                attributes.append(attribute)
            }
        }
        if let localIndex {
            keyIndex = localIndex
            keyIndexDirty = false
        } else {
            keyIndexDirty = true
        }
        lowercasedKeyIndexDirty = true
        lowercasedKeyIndex = nil
        lowercasedKeysCache = nil
        if touchedClass {
            ownerElement?.markClassQueryIndexDirty()
        }
        if touchedId {
            ownerElement?.markIdQueryIndexDirty()
        }
        ownerElement?.markAttributeQueryIndexDirty()
        ownerElement?.markAttributeValueQueryIndexDirty()
        ownerElement?.markSourceDirty()
        pendingAttributes?.removeAll(keepingCapacity: true)
    }

    internal func putMaterialized(_ attribute: Attribute) {
        let keySlice = attribute.keySlice
        let hasUppercase = Attributes.containsAsciiUppercase(keySlice)
        let normalizedKey = hasUppercase ? attribute.lowerKeySlice() : keySlice
        if let ix = indexForKey(keySlice) {
            attributes[ix] = attribute
            if !keyIndexDirty, keyIndex != nil {
                keyIndex?[keySlice] = ix
            }
        } else {
            attributes.append(attribute)
            if !keyIndexDirty, keyIndex != nil {
                keyIndex?[keySlice] = attributes.count - 1
            }
        }
        if !hasUppercaseKeys && hasUppercase {
            hasUppercaseKeys = true
        }
        invalidateLowercasedKeysCache()
        if equalsSlice(normalizedKey, UTF8Arrays.class_) {
            ownerElement?.markClassQueryIndexDirty()
        }
        if equalsSlice(normalizedKey, SwiftSoup.Element.idString) {
            ownerElement?.markIdQueryIndexDirty()
        }
        ownerElement?.markAttributeQueryIndexDirty()
        ownerElement?.markAttributeValueQueryIndexDirty(for: attribute.getKeyUTF8())
    }
    
    internal func updateLowercasedKeysCache() {
        ensureMaterialized()
        lowercasedKeysCache = Set(attributes.map { attr in
            attr.lowerKeySlice()
        })
    }

    internal func ensureLowercasedKeyIndex() {
        ensureMaterialized()
        guard shouldBuildKeyIndex() else { return }
        if lowercasedKeyIndexDirty || lowercasedKeyIndex == nil {
            var rebuilt: [ByteSlice: Int] = [:]
            rebuilt.reserveCapacity(attributes.count)
            for (index, attr) in attributes.enumerated() {
                let lowerKey = attr.lowerKeySlice()
                if rebuilt[lowerKey] == nil {
                    rebuilt[lowerKey] = index
                }
            }
            lowercasedKeyIndex = rebuilt
            lowercasedKeyIndexDirty = false
        }
    }
    
    internal func invalidateLowercasedKeysCache() {
        lowercasedKeysCache = nil
        lowercasedKeyIndex = nil
        lowercasedKeyIndexDirty = true
    }

    internal func invalidateKeyIndex() {
        keyIndex = nil
        keyIndexDirty = true
    }

    func shouldBuildKeyIndex() -> Bool {
        return attributes.count >= Self.keyIndexThreshold
    }

    func ensureKeyIndex() {
        ensureMaterialized()
        guard shouldBuildKeyIndex() else { return }
        if keyIndexDirty || keyIndex == nil {
            var rebuilt: [ByteSlice: Int] = [:]
            rebuilt.reserveCapacity(attributes.count)
            for (index, attr) in attributes.enumerated() {
                rebuilt[attr.keySlice] = index
            }
            keyIndex = rebuilt
            keyIndexDirty = false
        }
    }

    func indexForKey(_ key: [UInt8]) -> Int? {
        return indexForKey(ByteSlice.fromArray(key))
    }

    func indexForKey(_ key: ByteSlice) -> Int? {
        ensureMaterialized()
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureKeyIndex()
            return keyIndex?[key]
        }
        return attributes.firstIndex(where: { $0.keySlice == key })
    }
    
    /**
     Get an attribute value by key.
     - parameter key: the (case-sensitive) attribute key
     - returns: the attribute value if set; or empty string if not set.
     - seealso: ``hasKey(key:)-(String)``
     */
    func get(key: String) -> String {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return String(decoding: get(key: lookup), as: UTF8.self)
        }
        return String(decoding: get(key: key.utf8Array), as: UTF8.self)
    }
    
    func get(key: [UInt8]) -> [UInt8] {
        DebugTrace.log("Attributes.get(key): \(String(decoding: key, as: UTF8.self))")
        if attributes.isEmpty, let pendingValue = pendingValueCaseSensitive(key) {
            DebugTrace.log("Attributes.get: pending value hit")
            return pendingValue
        }
        ensureMaterialized()
        if let ix = indexForKey(key) {
            return attributes[ix].getValueUTF8()
        }
        return []
    }
    
    /**
     Get an attribute's value by case-insensitive key
     - parameter key: the attribute name
     - returns: the first matching attribute value if set; or empty string if not set.
     */
    func getIgnoreCase(key: String) throws -> String {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return try String(decoding: getIgnoreCase(key: lookup), as: UTF8.self)
        }
        return try String(decoding: getIgnoreCase(key: key.utf8Array), as: UTF8.self)
    }
    
    func getIgnoreCase(key: [UInt8]) throws -> [UInt8] {
        if attributes.isEmpty, let pendingValue = pendingValueIgnoreCase(key) {
            return pendingValue
        }
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                if let ix = lowercasedKeyIndex[lookupKey] {
                    return attributes[ix].getValueUTF8()
                }
                return []
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        guard lowercasedKeysCache?.contains(normalizedKey) ?? false else { return [] }
        if !hasUppercaseKeys {
            if let ix = indexForKey(normalizedKey) {
                return attributes[ix].getValueUTF8()
            }
            return []
        }
        if let attr = attributes.first(where: { equalsIgnoreCase($0.keySlice, key) }) {
            return attr.getValueUTF8()
        }
        return []
    }

    internal func getIgnoreCaseSlice(key: [UInt8]) throws -> ByteSlice {
        if attributes.isEmpty {
            if let pendingSlice = pendingValueIgnoreCaseSlice(key) {
                return pendingSlice
            }
            if let pendingValue = pendingValueIgnoreCase(key) {
                return ByteSlice.fromArray(pendingValue)
            }
        }
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if !Self.disableLowercasedKeyIndex, shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                if let ix = lowercasedKeyIndex[lookupKey] {
                    return attributes[ix].valueSliceMaterialized()
                }
                return ByteSlice.empty
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        guard lowercasedKeysCache?.contains(normalizedKey) ?? false else { return ByteSlice.empty }
        if !hasUppercaseKeys {
            if let ix = indexForKey(normalizedKey) {
                return attributes[ix].valueSliceMaterialized()
            }
            return ByteSlice.empty
        }
        if let attr = attributes.first(where: { equalsIgnoreCase($0.keySlice, key) }) {
            return attr.valueSliceMaterialized()
        }
        return ByteSlice.empty
    }
    
    /**
     Set a new attribute, or replace an existing one by key.
     - parameter key: attribute key
     - parameter value: attribute value
     */
    func put(_ key: [UInt8], _ value: [UInt8]) throws {
        ensureMaterialized()
        let attr = try Attribute(key: key, value: value)
        put(attribute: attr)
    }
    
    func put(_ key: String, _ value: String) throws {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return try put(lookup, value.utf8Array)
        }
        return try put(key.utf8Array, value.utf8Array)
    }
    
    /**
     Set a new boolean attribute, remove attribute if value is false.
     - parameter key: attribute key
     - parameter value: attribute value
     */
    func put(_ key: [UInt8], _ value: Bool) throws {
        ensureMaterialized()
        if (value) {
            try put(attribute: BooleanAttribute(key: key))
        } else {
            try remove(key: key)
        }
    }
    
    /**
     Set a new attribute, or replace an existing one by (case-sensitive) key.
     - parameter attribute: attribute
     */
    func put(attribute: Attribute) {
        ensureMaterialized()
        putMaterialized(attribute)
    }
    
    /**
     Remove an attribute by key. <b>Case sensitive.</b>
     - parameter key: attribute key to remove
     */
    public func remove(key: String) throws {
        ensureMaterialized()
        if let lookup = UTF8Arrays.attributeLookup[key] {
            try remove(key: lookup)
            return
        }
        try remove(key: key.utf8Array)
    }
    
    public func remove(key: [UInt8]) throws {
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        if let ix = indexForKey(key) {
            attributes.remove(at: ix)
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeQueryIndexDirty()
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }
    }
    
    /**
     Remove an attribute by key. <b>Case insensitive.</b>
     - parameter key: attribute key to remove
     */
    func removeIgnoreCase(key: [UInt8]) throws {
        ensureMaterialized()
        try Validate.notEmpty(string: key)
        if let ix = attributes.firstIndex(where: { equalsIgnoreCase($0.keySlice, key) }) {
            let normalizedKey = key.lowercased()
            attributes.remove(at: ix)
            invalidateLowercasedKeysCache()
            invalidateKeyIndex()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeQueryIndexDirty()
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }
    }

    /**
     Remove multiple attributes by exact key bytes in a single pass.
     - parameter keys: attribute keys to remove (case sensitive)
     */
    func removeAll(keys: [[UInt8]]) {
        ensureMaterialized()
        guard !keys.isEmpty else { return }
        guard !attributes.isEmpty else { return }

        var removedKeys: [[UInt8]] = []
        removedKeys.reserveCapacity(Swift.min(keys.count, attributes.count))
        var writeIndex = 0
        let originalCount = attributes.count
        for readIndex in 0..<originalCount {
            let attr = attributes[readIndex]
            var shouldRemove = false
            for removalKey in keys {
                if equalsSlice(attr.keySlice, removalKey) {
                    shouldRemove = true
                    break
                }
            }
            if shouldRemove {
                removedKeys.append(attr.getKeyUTF8())
            } else {
                if writeIndex != readIndex {
                    attributes[writeIndex] = attr
                }
                writeIndex += 1
            }
        }

        guard !removedKeys.isEmpty else { return }
        if writeIndex < originalCount {
            attributes.removeLast(originalCount - writeIndex)
        }
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()

        if let ownerElement {
            for key in removedKeys {
                let normalizedKey = key.lowercased()
                if normalizedKey == UTF8Arrays.class_ {
                    ownerElement.markClassQueryIndexDirty()
                }
                if normalizedKey == SwiftSoup.Element.idString {
                    ownerElement.markIdQueryIndexDirty()
                }
                ownerElement.markAttributeValueQueryIndexDirty(for: key)
            }
            ownerElement.markAttributeQueryIndexDirty()
        }
    }

    /**
     Compact the attribute list in one pass, allowing in-place mutation of values.
     - parameter body: return whether to keep the attribute and optionally a new value.
     */
    func compactAndMutate(_ body: (Attribute) -> AttributeMutation) {
        ensureMaterialized()
        guard !attributes.isEmpty else { return }

        let ownerElement = self.ownerElement
        var didMutate = false
        var dirtyClass = false
        var dirtyId = false

        func markDirty(for key: [UInt8]) {
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                dirtyClass = true
            }
            if normalizedKey == SwiftSoup.Element.idString {
                dirtyId = true
            }
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
        }

        var writeIndex = 0
        let originalCount = attributes.count
        for readIndex in 0..<originalCount {
            let attr = attributes[readIndex]
            let decision = body(attr)
            if let newValue = decision.newValue {
                _ = attr.setValue(value: newValue)
                if ownerElement != nil {
                    markDirty(for: attr.getKeyUTF8())
                }
                didMutate = true
            }
            if decision.keep {
                if writeIndex != readIndex {
                    attributes[writeIndex] = attr
                }
                writeIndex += 1
            } else {
                if ownerElement != nil {
                    markDirty(for: attr.getKeyUTF8())
                }
                didMutate = true
            }
        }

        if writeIndex < originalCount {
            attributes.removeLast(originalCount - writeIndex)
            didMutate = true
        }

        guard didMutate else { return }

        invalidateLowercasedKeysCache()
        if writeIndex < originalCount {
            invalidateKeyIndex()
        }

        if let ownerElement {
            if dirtyClass {
                ownerElement.markClassQueryIndexDirty()
            }
            if dirtyId {
                ownerElement.markIdQueryIndexDirty()
            }
            ownerElement.markAttributeQueryIndexDirty()
        }
    }

    internal func appendValueSlice(key: [UInt8], slice: ByteSlice) {
        ensureMaterialized()
        guard !key.isEmpty else { return }
        if let ix = indexForKey(key) {
            attributes[ix].appendValueSlice(slice)
            let normalizedKey = key.lowercased()
            if normalizedKey == UTF8Arrays.class_ {
                ownerElement?.markClassQueryIndexDirty()
            }
            if normalizedKey == SwiftSoup.Element.idString {
                ownerElement?.markIdQueryIndexDirty()
            }
            ownerElement?.markAttributeValueQueryIndexDirty(for: key)
            ownerElement?.markSourceDirty()
            return
        }
        let keySlice = ByteSlice.fromArray(key).trim()
        // Drop a malformed key rather than trapping; jsoup does the same. See #392.
        guard let attribute = try? Attribute(keySlice: keySlice, valueSlice: slice) else { return }
        putMaterialized(attribute)
        ownerElement?.markSourceDirty()
    }

    
    /**
     Tests if these attributes contain an attribute with this key.
     - parameter key: case-sensitive key to check for
     - returns: true if key exists, false otherwise
     */
    func hasKey(key: String) -> Bool {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return hasKey(key: lookup)
        }
        return hasKey(key: key.utf8Array)
    }
    
    func hasKey(key: [UInt8]) -> Bool {
        if attributes.isEmpty, pendingHasKeyCaseSensitive(key) {
            return true
        }
        ensureMaterialized()
        return indexForKey(key) != nil
    }
    
    /**
     Tests if these attributes contain an attribute with this key.
     - parameter key: key to check for
     - returns: true if key exists, false otherwise
     */
    func hasKeyIgnoreCase(key: String) -> Bool {
        if let lookup = UTF8Arrays.attributeLookup[key] {
            return hasKeyIgnoreCase(key: lookup)
        }
        return hasKeyIgnoreCase(key: key.utf8Array)
    }

    func hasKeyIgnoreCase(key: [UInt8]) -> Bool {
        if attributes.isEmpty, pendingHasKeyIgnoreCase(key) {
            return true
        }
        ensureMaterialized()
        guard !key.isEmpty else { return false }
        let keySlice = ByteSlice.fromArray(key)
        let hasUppercase = Attributes.containsAsciiUppercase(key)
        if shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                let lookupKey = hasUppercase ? keySlice.lowercased() : keySlice
                return lowercasedKeyIndex[lookupKey] != nil
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        let normalizedKey = hasUppercase ? keySlice.lowercased() : keySlice
        return lowercasedKeysCache!.contains(normalizedKey)
    }

    internal static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        return (byte >= 65 && byte <= 90) ? (byte + 32) : byte
    }

    
    func hasKeyIgnoreCase<T: Collection>(key: T) -> Bool where T.Element == UInt8 {
        if attributes.isEmpty, pendingHasKeyIgnoreCase(key) {
            return true
        }
        ensureMaterialized()
        guard !key.isEmpty else { return false }
        if shouldBuildKeyIndex() {
            ensureLowercasedKeyIndex()
            if let lowercasedKeyIndex {
                if let key = key as? [UInt8], key.allSatisfy({ $0 < 65 || $0 > 90 }) {
                    return lowercasedKeyIndex[ByteSlice.fromArray(key)] != nil
                }
                var lowerQuery: [UInt8] = []
                lowerQuery.reserveCapacity(key.count)
                for b in key {
                    lowerQuery.append(Self.asciiLowercase(b))
                }
                return lowercasedKeyIndex[ByteSlice.fromArray(lowerQuery)] != nil
            }
        }
        if lowercasedKeysCache == nil {
            updateLowercasedKeysCache()
        }
        if let key = key as? [UInt8], key.allSatisfy({ $0 < 65 || $0 > 90 }) {
            return lowercasedKeysCache!.contains(ByteSlice.fromArray(key))
        }
        var lowerQuery: [UInt8] = []
        lowerQuery.reserveCapacity(key.count)
        for b in key {
            lowerQuery.append(Self.asciiLowercase(b))
        }
        return lowercasedKeysCache!.contains(ByteSlice.fromArray(lowerQuery))
    }

    internal func pendingHasKeyCaseSensitive(_ key: [UInt8]) -> Bool {
        return pendingValueCaseSensitive(key) != nil
    }

    internal func pendingHasKeyIgnoreCase<T: Collection>(_ key: T) -> Bool where T.Element == UInt8 {
        return pendingValueIgnoreCase(key) != nil
    }

    internal func pendingValueCaseSensitive(_ key: [UInt8]) -> [UInt8]? {
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty else {
            return nil
        }
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                if nameBytes == key {
                    return materializePendingValue(pendingAttr.value)
                }
            } else if let nameSlice = pendingAttr.nameSlice {
                if equalsSlice(nameSlice, key) {
                    return materializePendingValue(pendingAttr.value)
                }
            }
        }
        return nil
    }

    internal func pendingValueCaseSensitiveSlice(_ key: [UInt8]) -> ByteSlice? {
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty else {
            return nil
        }
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                if nameBytes == key {
                    switch pendingAttr.value {
                    case .none, .empty:
                        return ByteSlice.empty
                    case .slice(let slice):
                        return slice
                    case .bytes(let bytes):
                        return ByteSlice.fromArray(bytes)
                    default:
                        return nil
                    }
                }
            } else if let nameSlice = pendingAttr.nameSlice {
                if equalsSlice(nameSlice, key) {
                    switch pendingAttr.value {
                    case .none, .empty:
                        return ByteSlice.empty
                    case .slice(let slice):
                        return slice
                    case .bytes(let bytes):
                        return ByteSlice.fromArray(bytes)
                    default:
                        return nil
                    }
                }
            }
        }
        return nil
    }

    internal func valueSliceCaseSensitive(_ key: [UInt8]) -> ByteSlice? {
        if attributes.isEmpty {
            if let pendingSlice = pendingValueCaseSensitiveSlice(key) {
                return pendingSlice
            }
            if let pendingValue = pendingValueCaseSensitive(key) {
                return ByteSlice.fromArray(pendingValue)
            }
            return nil
        }
        ensureMaterialized()
        if let ix = indexForKey(key) {
            return attributes[ix].valueSliceMaterialized()
        }
        return nil
    }

    internal func pendingValueIgnoreCase<T: Collection>(_ key: T) -> [UInt8]? where T.Element == UInt8 {
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty else {
            return nil
        }
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                if equalsIgnoreCase(nameBytes, key) {
                    return materializePendingValue(pendingAttr.value)
                }
            } else if let nameSlice = pendingAttr.nameSlice {
                if equalsIgnoreCase(nameSlice, key) {
                    return materializePendingValue(pendingAttr.value)
                }
            }
        }
        return nil
    }

    internal func pendingValueIgnoreCaseSlice<T: Collection>(_ key: T) -> ByteSlice? where T.Element == UInt8 {
        guard !key.isEmpty, attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty else {
            return nil
        }
        for pendingAttr in pending {
            if let nameBytes = pendingAttr.nameBytes {
                if equalsIgnoreCase(nameBytes, key) {
                    switch pendingAttr.value {
                    case .none, .empty:
                        return ByteSlice.empty
                    case .slice(let slice):
                        return slice
                    case .bytes(let bytes):
                        return ByteSlice.fromArray(bytes)
                    default:
                        return nil
                    }
                }
            } else if let nameSlice = pendingAttr.nameSlice {
                if equalsIgnoreCase(nameSlice, key) {
                    switch pendingAttr.value {
                    case .none, .empty:
                        return ByteSlice.empty
                    case .slice(let slice):
                        return slice
                    case .bytes(let bytes):
                        return ByteSlice.fromArray(bytes)
                    default:
                        return nil
                    }
                }
            }
        }
        return nil
    }

    internal func materializePendingValue(_ value: PendingAttrValue) -> [UInt8] {
        switch value {
        case .none:
            return []
        case .empty:
            return []
        case .slice(let slice):
            return Array(slice)
        case .slices(let slices, let count):
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for slice in slices {
                bytes.append(contentsOf: slice)
            }
            return bytes
        case .bytes(let bytes):
            return bytes
        }
    }

    internal func equalsSlice(_ slice: ByteSlice, _ key: [UInt8]) -> Bool {
        if slice.count != key.count {
            return false
        }
        var i = key.startIndex
        var j = slice.startIndex
        let end = key.endIndex
        while i < end {
            if key[i] != slice[j] {
                return false
            }
            i = key.index(after: i)
            j = slice.index(after: j)
        }
        return true
    }

    internal func equalsIgnoreCase<T: Collection>(_ bytes: [UInt8], _ key: T) -> Bool where T.Element == UInt8 {
        if bytes.count != key.count {
            return false
        }
        var i = bytes.startIndex
        for b in key {
            if Self.asciiLowercase(bytes[i]) != Self.asciiLowercase(b) {
                return false
            }
            i = bytes.index(after: i)
        }
        return true
    }

    internal func equalsIgnoreCase<T: Collection>(_ slice: ByteSlice, _ key: T) -> Bool where T.Element == UInt8 {
        if slice.count != key.count {
            return false
        }
        var i = slice.startIndex
        for b in key {
            if Self.asciiLowercase(slice[i]) != Self.asciiLowercase(b) {
                return false
            }
            i = slice.index(after: i)
        }
        return true
    }
    
    /**
     Get the number of attributes in this set.
     - returns: size
     */
    public func size() -> Int {
        ensureMaterialized()
        return attributes.count
    }
    
    /**
     Add all the attributes from the incoming set to this set.
     - parameter incoming: attributes to add to these attributes.
     */
    func addAll(incoming: Attributes?) {
        ensureMaterialized()
        guard let incoming = incoming else { return }
        incoming.ensureMaterialized()
        for attr in incoming.attributes {
            put(attribute: attr)
        }
    }
    
    /**
     Get the attributes as a List, for iteration. Do not modify the keys of the attributes via this view, as changes
     to keys will not be recognised in the containing set.
     - returns: an view of the attributes as a List.
     */
    public func asList() -> [Attribute] {
        ensureMaterialized()
        return attributes
    }
    
    /**
     Retrieves a filtered view of attributes that are HTML5 custom data attributes; that is, attributes with keys
     starting with `data-`.
     - returns: map of custom data attributes.
     */
    func dataset() -> [String: String] {
        ensureMaterialized()
        let prefixLength = Attributes.dataPrefix.count
        var result: [String: String] = [:]
        result.reserveCapacity(attributes.count)
        for attr in attributes where attr.isDataAttribute() {
            let key = attr.getKey().substring(prefixLength)
            let value = String(decoding: attr.valueSliceMaterialized(), as: UTF8.self)
            result[key] = value
        }
        return result
    }
    
    /**
     Get the HTML representation of these attributes.
     - returns: HTML
     */
    public func html() throws -> String {
        let accum = StringBuilder()
        try html(accum: accum, out: Document([]).outputSettings()) // output settings a bit funky, but this html() seldom used
        return accum.toString()
    }
    
    /**
     Get the HTML representation of these attributes.
     - returns: HTML
     */
    func htmlUTF8() throws -> [UInt8] {
        let accum = StringBuilder()
        try html(accum: accum, out: Document([]).outputSettings()) // output settings a bit funky, but this html() seldom used
        return Array(accum.buffer)
    }

    internal func appendPendingHtml(_ attr: PendingAttribute, _ accum: StringBuilder, _ out: OutputSettings) {
        let keySlice: ByteSlice
        if let nameSlice = attr.nameSlice {
            keySlice = nameSlice.trim()
        } else if let nameBytes = attr.nameBytes {
            keySlice = ByteSlice.fromArray(nameBytes).trim()
        } else {
            return
        }
        accum.append(keySlice)

        var valueSlice: ByteSlice? = nil
        var hasValue = false
        switch attr.value {
        case .none:
            hasValue = false
        case .empty:
            hasValue = true
            valueSlice = ByteSlice.empty
        case .slice(let slice):
            hasValue = true
            valueSlice = slice
        case .slices(let slices, let count):
            hasValue = true
            var combined: [UInt8] = []
            combined.reserveCapacity(count)
            for slice in slices {
                combined.append(contentsOf: slice)
            }
            valueSlice = ByteSlice.fromArray(combined)
        case .bytes(let bytes):
            hasValue = true
            valueSlice = ByteSlice.fromArray(bytes)
        }
        let keyLower = attr.hasUppercase ? keySlice.lowercased() : keySlice
        let isImplicitBoolean = {
            switch attr.value {
            case .none: return true
            default: return false
            }
        }()
        let isBoolean = isImplicitBoolean || Attribute.booleanAttributes.contains(keyLower)

        var shouldCollapse = false
        if out.syntax() == OutputSettings.Syntax.html && isBoolean {
            if !hasValue {
                shouldCollapse = true
            } else if let valueSlice {
                shouldCollapse = valueSlice.isEmpty
            }
        }

        if !shouldCollapse {
            accum.append(UTF8Arrays.attributeEqualsQuoteMark)
            if let valueSlice {
                Attribute.appendAttributeValue(accum, out, valueSlice)
            }
            accum.append(UTF8Arrays.quoteMark)
        }
    }
    
    func html(accum: StringBuilder, out: OutputSettings ) throws {
        if attributes.isEmpty, let pending = pendingAttributes, !pending.isEmpty {
            for attr in pending {
                accum.append(UTF8Arrays.whitespace)
                appendPendingHtml(attr, accum, out)
            }
            return
        }
        ensureMaterialized()
        for attr in attributes {
            accum.append(UTF8Arrays.whitespace)
            attr.html(accum: accum, out: out)
        }
    }
    
    func toString()throws -> String {
        return try html()
    }

    internal static func equalsIgnoreCase(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var i = lhs.startIndex
        var j = rhs.startIndex
        while i < lhs.endIndex {
            let b1 = lhs[i]
            let b2 = rhs[j]
            let lower1 = (b1 >= 65 && b1 <= 90) ? (b1 &+ 32) : b1
            let lower2 = (b2 >= 65 && b2 <= 90) ? (b2 &+ 32) : b2
            if lower1 != lower2 { return false }
            i = lhs.index(after: i)
            j = rhs.index(after: j)
        }
        return true
    }
    
    /**
     Checks if these attributes are equal to another set of attributes, by comparing the two sets
     - parameter o: attributes to compare with
     - returns: if both sets of attributes have the same content
     */
    func equals(o: AnyObject?) -> Bool {
        if(o == nil) {return false}
        if (self === o.self) {return true}
        guard let that = o as? Attributes else {return false}
        ensureMaterialized()
        that.ensureMaterialized()
        return (attributes == that.attributes)
    }
    
    func lowercaseAllKeys() {
        ensureMaterialized()
        guard hasUppercaseKeys else { return }
        for ix in attributes.indices {
            let lowered = attributes[ix].lowerKeySlice()
            attributes[ix].keySlice = lowered
            attributes[ix].keyBytes = nil
            attributes[ix].lowerKeySliceCache = lowered
        }
        hasUppercaseKeys = false
        invalidateLowercasedKeysCache()
        invalidateKeyIndex()
        ownerElement?.markClassQueryIndexDirty()
        ownerElement?.markIdQueryIndexDirty()
        ownerElement?.markAttributeQueryIndexDirty()
        ownerElement?.markAttributeValueQueryIndexDirty()
        ownerElement?.markSourceDirty()
    }
    
    public func copy(with zone: NSZone? = nil) -> Any {
        ensureMaterialized()
        let clone = Attributes()
        clone.attributes = attributes
        clone.hasUppercaseKeys = hasUppercaseKeys
        clone.lowercasedKeysCache = nil
        clone.lowercasedKeyIndex = nil
        clone.lowercasedKeyIndexDirty = true
        clone.keyIndex = nil
        clone.keyIndexDirty = true
        return clone
    }
    
    func clone() -> Attributes {
        ensureMaterialized()
        return self.copy() as! Attributes
    }
    
    fileprivate static func dataKey(key: [UInt8]) -> [UInt8] {
        return dataPrefix + key
    }
    
    internal static func containsAsciiUppercase(_ key: [UInt8]) -> Bool {
        for b in key {
            if b >= 65 && b <= 90 {
                return true
            }
        }
        return false
    }


    internal static func containsAsciiUppercase(_ key: ByteSlice) -> Bool {
        for b in key {
            if b >= 65 && b <= 90 {
                return true
            }
        }
        return false
    }
    
}

extension Attributes: Sequence {
    public func makeIterator() -> AnyIterator<Attribute> {
        ensureMaterialized()
        return AnyIterator(attributes.makeIterator())
    }
}
