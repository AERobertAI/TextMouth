import Foundation

/// Why a Kindle KFX book cannot be read, beyond what the MOBI reader already
/// says of any Kindle book. A KFX book that is copy-protected, damaged, or
/// not a Kindle book at all throws `MOBIError` (`copyProtected`, `damaged`,
/// `notAKindleBook`), so a listener hears one wording for each of those
/// whichever Kindle format the book is in. Every case here is a full
/// sentence a listener can act on; none names the file, which an import's
/// failure does (`ImportFailure`).
enum KFXError: LocalizedError, Equatable {
    /// The file is a DRM-free KFX container, which no layer of the reader
    /// walks yet. The first layer of the reader (recognize and refuse) ends
    /// here; the case goes when the walk is in.
    case notReadableYet
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
        case .notReadableYet:
            return "This Kindle book is in the newer KFX format, which TextMouth can't read yet."
        case .kindleCreatePackage:
            return "This file is a Kindle Create package, which TextMouth can't read yet."
        case .noFlowingText:
            return "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."
        case .partOfABook:
            return "This file holds only part of a Kindle book. Open the book's main .kfx file."
        }
    }
}
