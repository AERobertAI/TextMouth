import XCTest
@testable import TextMouth

/// `PhoneLibraryVocabulary`: each of the Mac's inline words the phone's
/// Library uses is read from the Mac's own view, word for word, so the two
/// apps can't drift apart unnoticed.
final class PhoneLibraryVocabularyTests: XCTestCase {
    /// The list's words are LibraryView's.
    func testTheListsWordsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.foldersHeader)\")"))
        XCTAssertTrue(macView.contains("prompt: \"\(PhoneLibraryVocabulary.searchPrompt)\""))
        XCTAssertTrue(macView.contains("Label(\"\(PhoneLibraryVocabulary.newFolderTitle)\", systemImage:"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"\(PhoneLibraryVocabulary.newFolderLabel)\")"))
        XCTAssertTrue(macView.contains("Label(\"\(PhoneLibraryVocabulary.sortTitle)\", systemImage:"))
        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.applySortToSubfolders)\")"))
    }

    /// A folder's commands are LibraryView's.
    func testAFoldersCommandsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.renameFolder)\")"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.moveFolder)\")"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.deleteFolder)\", role: .destructive)"))
    }

    /// Book Info is the book row's own command, in LibrarySubviews.
    func testBookInfoIsTheRowsCommand() throws {
        let macView = try Self.source("Views/Library/LibrarySubviews.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.bookInfo)\")"))
    }

    /// The Continue row's visible title and hint are the Continue button's.
    func testTheContinueRowsWordsAreTheContinueButtons() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.continueVisiblePrefix)\\(lastBook.title)\")"))
        XCTAssertTrue(macView.contains(".accessibilityHint(\"\(PhoneLibraryVocabulary.continueHint)\")"))
    }

    /// Removal's Cancel is the Mac's Remove Book question's.
    func testRemovalsCancelIsTheMacs() throws {
        let macView = try Self.source("Views/ContentView.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.cancel)\", role: .cancel)"))
    }

    /// Book Info's words are the Mac's simple Book Information sheet's, and
    /// what is said once saved is the Mac's reader's.
    func testBookInfosWordsAreTheMacs() throws {
        let sheet = try Self.source("Views/Library/LibrarySheetViews.swift")
        let reader = try Self.source("ViewModels/ReaderViewModel+Bookmarks.swift")

        XCTAssertTrue(sheet.contains("Text(\"\(PhoneLibraryVocabulary.bookInformation)\")"))
        XCTAssertTrue(sheet.contains("TextField(\"\(PhoneLibraryVocabulary.titleField)\", text: $title)"))
        XCTAssertTrue(sheet.contains("MetadataEditorWording.fieldLabel(\"\(PhoneLibraryVocabulary.titleFieldLabel)\", for: .title"))
        XCTAssertTrue(sheet.contains("TextField(\"\(PhoneLibraryVocabulary.authorField)\", text: $author)"))
        XCTAssertTrue(sheet.contains("MetadataEditorWording.fieldLabel(\"\(PhoneLibraryVocabulary.authorFieldLabel)\", for: .author"))
        XCTAssertTrue(sheet.contains("LabeledContent(\"\(PhoneLibraryVocabulary.formatRow)\")"))
        XCTAssertTrue(sheet.contains("LabeledContent(\"\(PhoneLibraryVocabulary.addedRow)\")"))
        XCTAssertTrue(sheet.contains("LabeledContent(\"\(PhoneLibraryVocabulary.lastOpenedRow)\")"))
        XCTAssertTrue(sheet.contains("LabeledContent(\"\(PhoneLibraryVocabulary.wordCountRow)\")"))
        XCTAssertTrue(sheet.contains("Button(\"\(PhoneLibraryVocabulary.save)\")"))
        XCTAssertTrue(sheet.contains("Button(\"\(PhoneLibraryVocabulary.cancel)\")"))
        XCTAssertTrue(reader.contains("announceToVoiceOver(\"\(PhoneLibraryVocabulary.metadataUpdated)\")"))
    }

    /// An EPUB's and an audiobook's Book Info words are the Mac's metadata
    /// editor's.
    func testRichBookInfosWordsAreTheMetadataEditors() throws {
        let editor = try Self.source("Views/Reader/MetadataEditorView.swift")

        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.publisherField)\", text: $editedEPUBMetadata.publisher)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.publisherField)\", for: .publisher)"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.publicationDateField)\", text: $editedEPUBMetadata.publicationDate)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.publicationDateFieldLabel)\", for: .publicationDate)"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.authorField)\", text: $editedEPUBMetadata.author)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.authorField)\", for: .author)"))
        XCTAssertTrue(editor.contains("LabeledContent(\"\(PhoneLibraryVocabulary.isbnRow)\")"))
        XCTAssertTrue(editor.contains("LabeledContent(\"\(PhoneLibraryVocabulary.languageRow)\")"))
        XCTAssertTrue(editor.contains("LabeledContent(\"\(PhoneLibraryVocabulary.identifierRow)\")"))
        XCTAssertTrue(editor.contains("LabeledContent(\"\(PhoneLibraryVocabulary.epubVersionRow)\")"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.artistField)\", text: $editedAudioMetadata.artist)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.artistFieldLabel)\", for: .author)"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.albumField)\", text: $editedAudioMetadata.album)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.albumFieldLabel)\", for: .audioAlbum)"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.genreField)\", text: $editedAudioMetadata.genre)"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.yearField)\", text: $editedAudioMetadata.year)"))
        XCTAssertTrue(editor.contains("LabeledContent(\"\(PhoneLibraryVocabulary.durationRow)\")"))
        XCTAssertTrue(editor.contains("TextField(\"\(PhoneLibraryVocabulary.titleField)\", text: $editedAudioMetadata.title)"))
        XCTAssertTrue(editor.contains("fieldLabel(\"\(PhoneLibraryVocabulary.titleFieldLabel)\", for: .title)"))
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
