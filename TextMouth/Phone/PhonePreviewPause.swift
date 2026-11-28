import Foundation

/// Pauses the books that play while Preview Voice speaks, and plays them on
/// after (the spec, "The Voice & Speed sheet" and Settings' Voice section),
/// as Where Am I? does. Either of the session's two readers may be the one
/// playing, so it takes every reader that could.
///
/// It holds no reader itself, only what each can do, so a test on the Mac
/// stands in for the readers with plain values.
enum PhonePreviewPause {
    /// What the pause needs of one reader.
    struct Reader {
        /// Whether the book plays now.
        let isPlaying: @MainActor () -> Bool
        /// Pauses it.
        let pause: @MainActor () -> Void
        /// Plays it on.
        let resume: @MainActor () -> Void
    }

    /// Pauses each of `readers` that plays, and returns what plays on those
    /// it paused, or nil when none was playing. The resume leaves alone a
    /// book that plays by then: the listener started it meanwhile, and a
    /// second Play would only restart it.
    @MainActor
    static func pause(_ readers: [Reader]) -> (@MainActor () -> Void)? {
        let paused = readers.filter { $0.isPlaying() }
        guard !paused.isEmpty else { return nil }
        for reader in paused {
            reader.pause()
        }
        return {
            for reader in paused where !reader.isPlaying() {
                reader.resume()
            }
        }
    }
}
