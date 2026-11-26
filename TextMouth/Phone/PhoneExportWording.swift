import Foundation

/// The words the iPhone's Export sheet says that the Mac's Export dialog has
/// no words for (FR31). Everything else the sheet says is the Mac's own,
/// called where it lives (`BookExportWording`, `BookExportDeepChapterWording`,
/// `BrailleExportWording`); only the iPhone's views and tests use this type, so
/// nothing here changes the Mac.
enum PhoneExportWording {
    /// Why a book's text was not converted: too little memory is left to the
    /// app for the conversion, which holds the whole text and the file it
    /// makes in memory. Said after the file's name in the export's failure
    /// sentence, as in "Couldn't export Moby-Dick - Text.html: The iPhone has
    /// too little memory free to convert this book now. Close other apps,
    /// then export again."; the other books are still exported.
    static var tooLittleMemory: String {
        // Translators: Why an export on the iPhone could not convert a book's text, after the file's name in a failure sentence: the iPhone has too little memory left for it.
        InterfaceText.line("phoneExport.tooLittleMemory", "The iPhone has too little memory free to convert this book now. Close other apps, then export again.")
    }

    /// The hint of Close, which takes Stop's place in the sheet's bar while the spoken audio file is made: the sheet
    /// closes and the export goes on, shown by a card at the top of the Library.
    static var closeWhileExporting: String {
        // Translators: The hint of the Close button of the Export sheet on the iPhone while a spoken audio export runs: the sheet closes, the export goes on, and the Library shows its progress.
        InterfaceText.line("phoneExport.closeWhileExporting", "Closes Export. The export goes on, and the Library shows how far it has come.")
    }

    /// The title of the button after an export that opens the system's share sheet for the files just written.
    static var share: String {
        // Translators: The title of the button on the iPhone's Export sheet, after an export, that opens the share sheet for the files just written.
        InterfaceText.line("phoneExport.share", "Share…")
    }

    /// What Share… does, for VoiceOver.
    static var shareHint: String {
        // Translators: The hint of the Share button on the iPhone's Export sheet, after an export.
        InterfaceText.line("phoneExport.shareHint", "Sends the files just exported to another app or person.")
    }

    /// Export's hint while another export is running: a second would end the first's card and task.
    static var anotherExportRuns: String {
        // Translators: The hint of the dimmed Export button on the iPhone's Export sheet while another export is running.
        InterfaceText.line("phoneExport.anotherExportRuns", "Another export is running. Its card is at the top of the Library.")
    }

    /// What VoiceOver says when Close takes Stop's place in the bar and focus moves to the Stop row: the sheet may close now.
    static var canCloseNow: String {
        // Translators: Said by VoiceOver on the iPhone's Export sheet when the spoken audio file is being made and the sheet may be closed.
        InterfaceText.line("phoneExport.canCloseNow", "You can close this. The export goes on.")
    }

    /// What starts the end's sentence of an export that iOS stopped, by its expiry or by Cancel in the Live Activity, so that
    /// it is told from the person's own Stop.
    static var stoppedBySystem: String {
        // Translators: Starts what an export says at its end when iOS stopped it, not the person. "iOS" is the name of the operating system.
        InterfaceText.line("phoneExport.stoppedBySystem", "iOS stopped this export.")
    }

    /// What ends the sentence of an export that stopped because a question about a chapter nested too deeply came with the
    /// sheet closed, so that nobody could answer it.
    static var questionWithNoSheet: String {
        // Translators: Ends what an export says when it stopped because it needed to ask what to do with a chapter nested too deeply, and the Export sheet was closed.
        InterfaceText.line("phoneExport.questionWithNoSheet", "A chapter nested too deeply needed a question, and the sheet was closed, so the export stopped.")
    }
}
