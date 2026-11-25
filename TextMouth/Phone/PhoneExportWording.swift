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
}
