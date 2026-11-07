import Foundation

/// The iPhone's hooks into a reader: closures the phone's own code fills, which
/// the reader calls at a few fixed points, each under `#if os(iOS)`. So a slice
/// changes what a reader does on the phone by filling a closure, never by
/// editing the reader's functions again. The reader keeps them in `phoneHooks`,
/// which exists on iOS alone; the Mac compiles this type and never uses it.
///
/// Every default leaves the reader doing what it does on the Mac.
struct ReaderPhoneHooks {
    /// Asked before the reader's audio starts, speech or an audiobook: false
    /// keeps it from starting, as when the audio session cannot be made active.
    /// The audio slice adds the places that ask, in `ReaderViewModel+Playback`.
    var audioMayStart: @MainActor () -> Bool = { true }

    /// Moves forward by the reader's unit in place of `skipForward()`, for a
    /// system command's skip (the AirPods' double press, Control Center), so
    /// that every move on the phone takes one path. Nil keeps `skipForward()`.
    var moveForward: (@MainActor () -> Void)?

    /// Moves back by the reader's unit in place of `skipBackward()`, as
    /// `moveForward` does. Nil keeps `skipBackward()`.
    var moveBackward: (@MainActor () -> Void)?

    /// Told when the book's audio has ended or gone silent for good, so the
    /// phone can let go of what it held for it. The places that tell are the
    /// audio slice's to add. Nil tells no one.
    var audioEnded: (@MainActor () -> Void)?
}
