import SwiftUI

// MARK: - Edit Audio… in the Menus

/// Whether the book of the reader whose window is key is an audiobook whose
/// audio Book > Edit Audio… can edit (FR04). The reader publishes it as a
/// scene value (`ReaderBookCommandsSupport`), so the menu item follows the
/// reader in front even while none of its views has keyboard focus.
struct CanEditBookAudioKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// Whether Book > Edit Audio… can act on the key reader's book.
    var canEditBookAudio: Bool? {
        get { self[CanEditBookAudioKey.self] }
        set { self[CanEditBookAudioKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by Book > Edit Audio… (FR04): the key reader opens the audio
    /// editor on its book.
    static let editBookAudio = Notification.Name("editBookAudio")
    /// Posted as the audio editor opens on a book open in a reader (FR04),
    /// with the book's identity as its object: that book's reader closes,
    /// since editing changes the audio it plays.
    static let closeReaderForAudioEditing = Notification.Name("closeReaderForAudioEditing")
}
