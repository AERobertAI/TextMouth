import Foundation

/// An audio command of a library row: an item of the row's context menu and
/// one of its VoiceOver actions, under the same name, acting on the same
/// books. Transcription's (FR05), and Edit Audio… (FR04), which opens an
/// audiobook in the audio editor.
enum LibraryTranscriptionCommand: Hashable, Identifiable {
    /// Edit Audio…, for one audiobook in a package of its own: opens it in
    /// the audio editor (FR04).
    case editAudio(Book)
    /// Transcribe Audio…, for the books the row's commands act on: one
    /// audiobook opens the Transcribe Audio sheet, and several books are
    /// refused with a sentence, as transcription works on one at a time.
    case transcribe([Book])
    /// Clean Up Transcript (Experimental)…, for one transcribed audiobook:
    /// opens the Clean Up sheet, which shows what the rules would change
    /// before anything does.
    case cleanUpTranscript(Book)
    /// Delete Transcript…, for one transcribed audiobook, after a
    /// confirmation naming it.
    case deleteTranscript(Book)

    var id: String {
        title
    }

    /// The command's name, in the menu and among VoiceOver's actions.
    var title: String {
        switch self {
        case .editAudio:
            return AudioEditorWording.editAudioCommand
        case .transcribe:
            return TranscriptionWording.transcribeCommandTitle
        case .cleanUpTranscript:
            return TranscriptCleanupWording.commandTitle
        case .deleteTranscript:
            return TranscriptionWording.deleteCommandTitle
        }
    }

    /// The commands a row offers for `targets`, the books its commands act
    /// on, given which books `isTranscribed` says have a transcript: Edit
    /// Audio… when the row acts on one such audiobook alone, then Transcribe
    /// Audio… whenever one of them is an audiobook in a package of its own,
    /// then Clean Up Transcript (Experimental)… and Delete Transcript… when
    /// the row acts on one such audiobook alone and it is transcribed;
    /// nothing for text books alone.
    static func commands(for targets: [Book], isTranscribed: (UUID) -> Bool = { _ in false }) -> [LibraryTranscriptionCommand] {
        guard targets.contains(where: isTranscribable) else { return [] }
        var commands: [LibraryTranscriptionCommand] = []
        let single = targets.count == 1 ? targets.first : nil
        if let book = single, isTranscribable(book) {
            commands.append(.editAudio(book))
        }
        commands.append(.transcribe(targets))
        if let book = single, isTranscribable(book), isTranscribed(book.id) {
            commands += [.cleanUpTranscript(book), .deleteTranscript(book)]
        }
        return commands
    }

    /// Whether `book` is an audiobook whose package a transcript, or an edit
    /// history, can be saved into.
    static func isTranscribable(_ book: Book) -> Bool {
        book.format.isAudio && !book.tmbDirectoryName.isEmpty
    }
}
