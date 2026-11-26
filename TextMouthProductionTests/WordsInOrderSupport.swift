import XCTest

// MARK: - Words in Order

extension XCTestCase {
    /// The first of `words` missing from `available` when both are read in
    /// order (`words` a subsequence of `available`), or nil when none is:
    /// how an export's tests on real books check that every word the reader
    /// reads reaches what was written. In a file of its own, so that the
    /// walker's tests, which the iPhone's unit bundle shares, can use it
    /// without the Mac's conversion tests.
    func firstWordMissing(of words: [String], from available: [String]) -> String? {
        var next = available.startIndex
        for word in words {
            guard let found = available[next...].firstIndex(of: word) else { return word }
            next = available.index(after: found)
        }
        return nil
    }
}
