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
}
