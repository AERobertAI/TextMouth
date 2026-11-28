import Foundation
@testable import TextMouth

/// A page marker as content.md carries it, for the tests that write one into a Markdown text. In a file
/// of its own, so that the export walker's tests, which the iPhone's unit bundle shares, need not take the
/// whole Markdown walk corpus (`MarkdownWalkCorpusKit`, which reads the Mac's test data) with them.
enum MarkdownMarkers {
    /// A page marker as content.md carries it.
    static func page(_ label: String) -> String {
        "\(MarkdownPageMarker.prefix)\(label)\(MarkdownPageMarker.suffix)"
    }
}
