//
//  BooleanAttribute.swift
//  SwifSoup
//
//  Created by Nabil Chatbi on 29/09/16.
//

import Foundation

/**
 * A boolean attribute that is written out without any value.
 */
final class BooleanAttribute: Attribute {
    /**
     Create a new boolean attribute from unencoded (raw) key.
     - parameter key: attribute key
     */
    init(key: [UInt8]) throws {
        try super.init(key: key, value: [])
    }

    init(keySlice: ByteSlice) throws {
        try super.init(keySlice: keySlice, valueSlice: ByteSlice.empty)
    }

    public convenience init(keySlice: ArraySlice<UInt8>) throws {
        try self.init(key: Array(keySlice))
    }

    override func isBooleanAttribute() -> Bool {
        return true
    }
}
