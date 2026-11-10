import Foundation

/// A sheet over the reader: the panels the reader opens, each over the reader
/// and each returning focus to the control that opened it. The reader's
/// screen presents one at a time, by this value; the panels' slice makes each.
enum PhoneReaderSheet: String, Identifiable, CaseIterable, Sendable {
    case bookmarks
    case headings
    case search
    case goTo
    case sleepTimer
    case voice
    case bookInfo
    case navigationUnit

    /// The sheet itself, for SwiftUI's `sheet(item:)`.
    var id: String { rawValue }
}
