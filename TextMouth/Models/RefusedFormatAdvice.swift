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
        String(localized: "Export Pages documents from Pages as Word documents or EPUB books, then import those.",
               comment: "Advice after the refusal of a Pages document: how to get the book out of Pages.")
    }
    /// Keynote presentations. TextMouth reads no slide format, so a PDF is the way.
    static var keynote: String {
        String(localized: "Export Keynote presentations from Keynote as PDF files, then import those.",
               comment: "Advice after the refusal of a Keynote presentation, which TextMouth reads in no slide format.")
    }
    /// Numbers spreadsheets, for the same reason.
    static var numbers: String {
        String(localized: "Export Numbers spreadsheets from Numbers as PDF files, then import those.",
               comment: "Advice after the refusal of a Numbers spreadsheet.")
    }
    /// WordPerfect documents, which no part of macOS reads.
    static var wordPerfect: String {
        String(localized: "Save WordPerfect documents as Word or HTML files in a program that reads them, such as LibreOffice, then import those.",
               comment: "Advice after the refusal of a WordPerfect document, which no part of macOS reads. LibreOffice is a program's name.")
    }
    /// Compiled HTML Help files.
    static var compiledHelp: String {
        String(localized: "Convert Compiled HTML Help files to HTML files or PDF files, then import those.",
               comment: "Advice after the refusal of a Compiled HTML Help file.")
    }
    /// DjVu scans.
    static var djVu: String {
        String(localized: "Convert DjVu documents to PDF files, then import those.",
               comment: "Advice after the refusal of a DjVu scan.")
    }
    /// XPS documents.
    static var xps: String {
        String(localized: "Convert XPS documents to PDF files, then import those.",
               comment: "Advice after the refusal of an XPS document.")
    }
    /// A comic whose pages are in a RAR archive, which TextMouth does not open.
    static var rarComic: String {
        String(localized: "Repack the pages of RAR comics as CBZ comics, then import those.",
               comment: "Advice after the refusal of a comic whose pages are in a RAR archive.")
    }
    /// A RAR archive that is no comic.
    static var rarArchive: String {
        String(localized: "TextMouth does not open RAR archives. Unpack them, then import what they hold.",
               comment: "Advice after the refusal of a RAR archive that is no comic.")
    }
    /// Audio that is locked to a store's own player.
    static var copyProtected: String {
        String(localized: "TextMouth cannot open copy-protected files.",
               comment: "Advice after the refusal of audio that is locked to a store's own player, such as Audible's .aa and .aax files.")
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
