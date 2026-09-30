import Foundation
import XCTest

/// Helpers for tests that hand parsers damaged copies of good files.
extension XCTestCase {
    /// `text` up to, not including, the first `marker`: a copy cut off
    /// partway, as an interrupted download or extraction leaves it.
    static func truncated(_ text: String, before marker: String) -> String {
        guard let range = text.range(of: marker) else {
            preconditionFailure("Fixture marker \(marker) not found")
        }
        return String(text[..<range.lowerBound])
    }

    /// `text` as UTF-8 with the byte 0xE9 inserted before the first `marker`.
    /// That byte is "é" in ISO Latin 1 but can never stand alone in UTF-8, as
    /// in a file a tool wrote in Latin 1 while declaring UTF-8.
    static func misencoded(_ text: String, before marker: String) -> Data {
        guard let range = text.range(of: marker) else {
            preconditionFailure("Fixture marker \(marker) not found")
        }
        var data = Data(text[..<range.lowerBound].utf8)
        data.append(0xE9)
        data.append(contentsOf: text[range.lowerBound...].utf8)
        return data
    }
}
