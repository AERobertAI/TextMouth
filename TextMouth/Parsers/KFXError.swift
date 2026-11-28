import Foundation

/// Why a Kindle KFX book cannot be read, beyond what the MOBI reader already
/// says of any Kindle book. A KFX book that is copy-protected, damaged, or
/// not a Kindle book at all throws `MOBIError` (`copyProtected`, `damaged`,
/// `notAKindleBook`), so a listener hears one wording for each of those
/// whichever Kindle format the book is in. Every case here is a full
/// sentence a listener can act on; none names the file, which an import's
/// failure does (`ImportFailure`).
enum KFXError: LocalizedError, LogDescribing, Equatable {
    /// The file is a Kindle Create package (a ZIP holding a `.kdf` database,
    /// the file Kindle Create and Kindle Previewer write for an author).
    /// TextMouth does not read it; it is a later item.
    case kindleCreatePackage
    /// The book has no flowing text to read: a fixed-layout book, a print
    /// replica, a comic, a magazine, a children's book, a notebook, or a
    /// book whose pages are only pictures.
    case noFlowingText
    /// The container holds no text of its own, such as the metadata file
    /// that sits beside a Kindle book's main file.
    case partOfABook

    var errorDescription: String? {
        switch self {
        case .kindleCreatePackage:
            // Translators: Why a file could not be imported: it is a package that Kindle Create writes for an author, which TextMouth does not read yet. Kindle Create is a program's name.
            return InterfaceText.line("kfxError.kindleCreatePackage", "This file is a Kindle Create package, which TextMouth can't read yet.")
        case .noFlowingText:
            // Translators: Why a Kindle (KFX) book could not be imported: its pages are fixed layouts or pictures, as in a comic or a print replica, with no text that flows.
            return InterfaceText.line("kfxError.noFlowingText", "This Kindle book has no flowing text, as in a comic or print replica, so TextMouth can't read it.")
        case .partOfABook:
            // Translators: Why a Kindle (KFX) file could not be imported: it is a part of a book, such as the metadata file beside the main file, and what to do. .kfx is a file extension and stays as it is.
            return InterfaceText.line("kfxError.partOfABook", "This file holds only part of a Kindle book. Open the book's main .kfx file.")
        }
    }

    /// The error in English for the debug log, which stays English whatever
    /// language the interface speaks (FR34).
    var logDescription: String {
        switch self {
        case .kindleCreatePackage: return "This file is a Kindle Create package, which TextMouth can't read yet." // l10n: no (debug log)
        case .noFlowingText: return "This Kindle book has no flowing text, as in a comic or print replica, so TextMouth can't read it." // l10n: no (debug log)
        case .partOfABook: return "This file holds only part of a Kindle book. Open the book's main .kfx file." // l10n: no (debug log)
        }
    }
}
