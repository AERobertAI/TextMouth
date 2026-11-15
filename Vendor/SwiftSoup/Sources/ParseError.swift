//
//  ParseError.swift
//  SwiftSoup
//
//  Created by Nabil Chatbi on 19/10/16.
//

import Foundation

/**
 * A Parse Error records an error in the input HTML that occurs in either the tokenisation or the tree building phase.
 */
final class ParseError {
    private let pos: Int
    private let errorMsg: String

    init(_ pos: Int, _ errorMsg: String) {
        self.pos = pos
        self.errorMsg = errorMsg
    }

    /**
     * Retrieve the error message.
     * - returns: the error message.
     */
    func getErrorMessage() -> String {
        return errorMsg
    }

    /**
     * Retrieves the offset of the error.
     * - returns: error offset within input
     */
    func getPosition() -> Int {
    return pos
    }

    func toString() -> String {
        return "\(pos): " + errorMsg
    }
}
