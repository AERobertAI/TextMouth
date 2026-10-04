import SwiftUI

// The Book menu's Clean Up Transcript (Experimental)… (FR05): the menu
// command posts `cleanUpBookTranscript`, which the reader whose window is
// key takes (`ReaderBookCommandsSupport`), and that reader says whether
// its book has a transcript to clean up.

/// Whether the book of the reader whose window is key is a transcribed
/// audiobook, whose transcript Clean Up Transcript (Experimental)… can
/// clean up. The reader publishes it as a scene value
/// (`ReaderBookCommandsSupport`).
struct CanCleanUpBookTranscriptKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canCleanUpBookTranscript: Bool? {
        get { self[CanCleanUpBookTranscriptKey.self] }
        set { self[CanCleanUpBookTranscriptKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by Book > Clean Up Transcript (Experimental)…: the reader
    /// whose window is key opens the Clean Up sheet for its book.
    static let cleanUpBookTranscript = Notification.Name("cleanUpBookTranscript")
}
