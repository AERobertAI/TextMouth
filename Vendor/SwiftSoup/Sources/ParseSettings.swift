//
//  ParseSettings.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 14/10/16.
//

import Foundation

final class ParseSettings: @unchecked Sendable {
    /**
     * HTML default settings: both tag and attribute names are lower-cased during parsing.
     */
    static let htmlDefault: ParseSettings = ParseSettings(false, false)
    /**
     * Preserve both tag and attribute case.
     */
    static let preserveCase: ParseSettings = ParseSettings(true, true)

    private let preserveTagCase: Bool
    private let preserveAttributeCase: Bool
    private let trackSourceRanges: Bool
    private let trackAttributes: Bool
    
    internal static let defaultTrackSourceRanges: Bool = true

    /**
     Define parse settings.
     - parameter tag: preserve tag case?
     - parameter attribute: preserve attribute name case?
     */
    public init(_ tag: Bool, _ attribute: Bool) {
        preserveTagCase = tag
        preserveAttributeCase = attribute
        trackSourceRanges = ParseSettings.defaultTrackSourceRanges
        trackAttributes = true
    }

    public init(_ tag: Bool, _ attribute: Bool, _ trackSourceRanges: Bool) {
        preserveTagCase = tag
        preserveAttributeCase = attribute
        self.trackSourceRanges = trackSourceRanges
        trackAttributes = true
    }

    public init(_ tag: Bool, _ attribute: Bool, _ trackSourceRanges: Bool, _ trackAttributes: Bool) {
        preserveTagCase = tag
        preserveAttributeCase = attribute
        self.trackSourceRanges = trackSourceRanges
        self.trackAttributes = trackAttributes
    }

    internal func preservesTagCase() -> Bool {
        return preserveTagCase
    }

    internal func preservesAttributeCase() -> Bool {
        return preserveAttributeCase
    }

    internal func tracksSourceRanges() -> Bool {
        return trackSourceRanges
    }

    internal func tracksAttributes() -> Bool {
        return trackAttributes
    }

    func normalizeTag(_ name: [UInt8]) -> [UInt8] {
        var name = name.trim()
        if (!preserveTagCase) {
            name = name.lowercased()
        }
        return name
    }

    internal func normalizeTag(_ name: ByteSlice) -> ByteSlice {
        var name = name.trim()
        if (!preserveTagCase) {
            name = name.lowercased()
        }
        return name
    }
    
    func normalizeTag(_ name: String) -> String {
        return String(decoding: normalizeTag(name.utf8Array), as: UTF8.self)
    }

    func normalizeAttribute(_ name: [UInt8]) -> [UInt8] {
        var name = name.trim()
        if (!preserveAttributeCase) {
            name = name.lowercased()
        }
        return name
    }

    internal func normalizeAttribute(_ name: ByteSlice) -> ByteSlice {
        var name = name.trim()
        if (!preserveAttributeCase) {
            name = name.lowercased()
        }
        return name
    }
    
    func normalizeAttribute(_ name: String) -> String {
        return String(decoding: normalizeAttribute(name.utf8Array), as: UTF8.self)
    }

    func normalizeAttributes(_ attributes: Attributes) throws -> Attributes {
        if (!preserveAttributeCase) {
            attributes.lowercaseAllKeys()
        }
        return attributes
    }

}
