//
//  SourceRange.swift
//  SwiftSoup
//
//  Created by Codex on 23/12/2025.
//

import Foundation

internal struct SourceRange: Equatable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    var isValid: Bool {
        return start >= 0 && end >= start
    }
}

internal struct SourcePatch: Equatable {
    var range: SourceRange
    var replacement: [UInt8]

    init(range: SourceRange, replacement: [UInt8]) {
        self.range = range
        self.replacement = replacement
    }
}
