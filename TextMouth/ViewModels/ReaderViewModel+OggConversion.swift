import AppKit

/// What a reader says when it will not play a book's Ogg audio (B06).
enum ReaderOggWording {
    /// What Play says while the book's audio is being converted.
    static let beingConverted = "This book's audio is being converted from Ogg to AAC. It plays once the conversion ends."
    /// What Play says for a book whose conversion failed at this launch: it
    /// is not tried again before the next one.
    static let conversionFailed = "This book's audio could not be converted from Ogg to AAC. "
        + "TextMouth tries again the next time it starts."
    /// What Play says for a book found still in Ogg, whose conversion it
    /// starts.
    static let needsConverting = "This book's audio needs converting from Ogg to AAC before it plays. "
        + "TextMouth is converting it now, and it plays once the conversion ends."
}

// MARK: - Ogg Audio Never Played (B06)

extension ReaderViewModel {
    /// Whether the current chapter's audio may be handed to the player as
    /// far as Ogg goes: never while the book's audio is being converted to
    /// AAC, and never from an Ogg file. On October 14, 2026 Apple's Vorbis
    /// decoder locked up playing Ogg through AVPlayer and took the Mac down,
    /// so Ogg is converted rather than played. A chapter still in Ogg, as a
    /// book not yet reached by the library's conversion is, asks the library
    /// to convert its book. Either way the reader stops at the chapter and
    /// says why, in the error alert and aloud.
    func chapterAudioIsClearOfOgg() -> Bool {
        guard isAudioBook else { return true }
        if libraryViewModel.oggConversion.isConverting(book.id) {
            refuseOggAudio(ReaderOggWording.beingConverted)
            return false
        }
        guard chapterAudioSource(forChapterAt: currentChapterIndex).files.contains(where: ImportAudioConverter.isOgg) else { // lint-ok: the library converts Ogg books alone, the one format converted at import before October 18
            return true
        }
        DiagnosticLog.event(
            .storage,
            "READER_READ_REFUSED: \(book.title): chapter \(currentChapterIndex + 1) is Ogg audio, which is converted to AAC first"
        )
        if libraryViewModel.oggConversion.hasFailed(book.id) {
            refuseOggAudio(ReaderOggWording.conversionFailed)
            return false
        }
        libraryViewModel.requestOggConversion(ofBook: book.id)
        refuseOggAudio(ReaderOggWording.needsConverting)
        return false
    }

    /// Stops the reader at the current chapter, and tells the listener
    /// `message` in the error alert and aloud.
    private func refuseOggAudio(_ message: String) {
        stop()
        errorMessage = message
        lastAnnouncement = message
        VoiceOverAnnouncer.announce(message, priority: .high)
    }
}
