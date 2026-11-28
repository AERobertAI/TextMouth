import Foundation

/// How to get a book out of a format TextMouth refuses (FMT02). One table
/// of extensions and sentences serves both the alert of a single file that
/// is refused (`FileImportError.unsupportedFormat`) and the alert of an
/// archive or folder that held no book (`ImportProgressWording
/// .noBooksFound(in:holding:)`), so the two never differ.
///
/// Each sentence names the kind of file in the plural and uses no pronoun,
/// so it reads the same after one file and after a list of kinds. VoiceOver
/// speaks it, so it holds no symbols and no letter-by-letter abbreviations
/// beyond those people say aloud (PDF, EPUB, HTML, CBZ).
enum RefusedFormatAdvice {
    /// Pages documents, whose newer form is a ZIP of undocumented files.
    static var pages: String {
        // Translators: Advice after the refusal of a Pages document: how to get the book out of Pages.
        InterfaceText.line("refusedFormatAdvice.pages", "Export Pages documents from Pages as Word documents or EPUB books, then import those.")
    }
    /// Keynote presentations. TextMouth reads no slide format, so a PDF is the way.
    static var keynote: String {
        // Translators: Advice after the refusal of a Keynote presentation, which TextMouth reads in no slide format.
        InterfaceText.line("refusedFormatAdvice.keynote", "Export Keynote presentations from Keynote as PDF files, then import those.")
    }
    /// Numbers spreadsheets, for the same reason.
    static var numbers: String {
        // Translators: Advice after the refusal of a Numbers spreadsheet.
        InterfaceText.line("refusedFormatAdvice.numbers", "Export Numbers spreadsheets from Numbers as PDF files, then import those.")
    }
    /// WordPerfect documents, which no part of macOS reads.
    static var wordPerfect: String {
        // Translators: Advice after the refusal of a WordPerfect document, which no part of macOS reads. LibreOffice is a program's name.
        InterfaceText.line("refusedFormatAdvice.wordPerfect", "Save WordPerfect documents as Word or HTML files in a program that reads them, such as LibreOffice, then import those.")
    }
    /// Compiled HTML Help files.
    static var compiledHelp: String {
        // Translators: Advice after the refusal of a Compiled HTML Help file.
        InterfaceText.line("refusedFormatAdvice.compiledHelp", "Convert Compiled HTML Help files to HTML files or PDF files, then import those.")
    }
    /// DjVu scans.
    static var djVu: String {
        // Translators: Advice after the refusal of a DjVu scan.
        InterfaceText.line("refusedFormatAdvice.djVu", "Convert DjVu documents to PDF files, then import those.")
    }
    /// XPS documents.
    static var xps: String {
        // Translators: Advice after the refusal of an XPS document.
        InterfaceText.line("refusedFormatAdvice.xps", "Convert XPS documents to PDF files, then import those.")
    }
    /// A comic whose pages are in a RAR archive, which TextMouth does not open.
    static var rarComic: String {
        // Translators: Advice after the refusal of a comic whose pages are in a RAR archive.
        InterfaceText.line("refusedFormatAdvice.rarComic", "Repack the pages of RAR comics as CBZ comics, then import those.")
    }
    /// A RAR archive that is no comic.
    static var rarArchive: String {
        // Translators: Advice after the refusal of a RAR archive that is no comic.
        InterfaceText.line("refusedFormatAdvice.rarArchive", "TextMouth does not open RAR archives. Unpack them, then import what they hold.")
    }
    /// Audio that is locked to a store's own player.
    static var copyProtected: String {
        // Translators: Advice after the refusal of audio that is locked to a store's own player, such as Audible's .aa and .aax files.
        InterfaceText.line("refusedFormatAdvice.copyProtected", "TextMouth cannot open copy-protected files.")
    }

    /// Every refused extension (lowercase, no dot) and its sentence. The one
    /// table behind `advice(forExtension:)` and `advice(for:)`.
    static var sentencesByExtension: [String: String] {
        [
            "pages": pages,
            "key": keynote,
            "numbers": numbers,
            "wpd": wordPerfect, "wp": wordPerfect,
            "chm": compiledHelp,
            "djvu": djVu, "djv": djVu,
            "xps": xps, "oxps": xps,
            "cbr": rarComic,
            "rar": rarArchive,
            // Audible's .aa and .aax (and .aaxc), and Apple's old protected .m4p.
            "aa": copyProtected, "aax": copyProtected, "aaxc": copyProtected, "m4p": copyProtected,
        ]
    }

    /// The advice for one file's extension, in any capitals and with or
    /// without a leading dot; nil for an extension the table does not know.
    static func advice(forExtension fileExtension: String) -> String? {
        var key = fileExtension.lowercased()
        if key.hasPrefix(".") { key.removeFirst() }
        return sentencesByExtension[key]
    }

    /// The advice for every kind among `files`, each sentence once and in
    /// the order the kinds are listed (most files first), joined as sentences;
    /// nil when no kind has advice. Two extensions that share a sentence
    /// (.aa and .aax) say it once.
    static func advice(for files: NonBookFiles) -> String? {
        var sentences: [String] = []
        for kind in files.kinds {
            if let sentence = advice(forExtension: kind.fileExtension), !sentences.contains(sentence) {
                sentences.append(sentence)
            }
        }
        return sentences.isEmpty ? nil : SentenceWording.joined(sentences)
    }
}
