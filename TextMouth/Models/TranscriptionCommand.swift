import Foundation

/// A transcription command of a library row (FR05): an item of the row's
/// context menu and one of its VoiceOver actions, under the same name,
/// acting on the same books.
enum LibraryTranscriptionCommand: Hashable, Identifiable {
    /// Transcribe Audio…, for the books the row's commands act on: one
    /// audiobook opens the Transcribe Audio sheet, and several books are
    /// refused with a sentence, as transcription works on one at a time.
    case transcribe([Book])

    var id: String {
        title
    }

    /// The command's name, in the menu and among VoiceOver's actions.
    var title: String {
        switch self {
        case .transcribe:
            return TranscriptionWording.transcribeCommandTitle
        }
    }

    /// The commands a row offers for `targets`, the books its commands act
    /// on: Transcribe Audio… whenever one of them is an audiobook in a
    /// package of its own, and nothing for text books alone.
    static func commands(for targets: [Book]) -> [LibraryTranscriptionCommand] {
        guard targets.contains(where: isTranscribable) else { return [] }
        return [.transcribe(targets)]
    }

    /// Whether `book` is an audiobook whose package a transcript can be
    /// saved into.
    static func isTranscribable(_ book: Book) -> Bool {
        book.format.isAudio && !book.tmbDirectoryName.isEmpty
    }
}
