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
        XCTAssertTrue(macView.contains("Label(\"\(PhoneFolderVocabulary.newFolderTitle)\", systemImage:"))
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

        XCTAssertTrue(macView.contains("Button(\"\(PhoneAppWording.cancel)\", role: .cancel)"))
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
        XCTAssertTrue(sheet.contains("Button(\"\(PhoneAppWording.save)\")"))
        XCTAssertTrue(sheet.contains("Button(\"\(PhoneAppWording.cancel)\")"))
        // The Mac reader's words after a save are its localized static, which the
        // phone reads rather than copies (FR35): the same words, their English
        // unchanged, and the reader's source says them through the static.
        XCTAssertEqual(PhoneLibraryVocabulary.metadataUpdated, ReaderViewModel.metadataUpdatedAnnouncement)
        XCTAssertEqual(ReaderViewModel.metadataUpdatedAnnouncement, "Metadata updated")
        XCTAssertTrue(reader.contains("announceToVoiceOver(Self.metadataUpdatedAnnouncement)"))
    }

    /// An EPUB's and an audiobook's Book Info words are the Mac's metadata
    /// editor's.
    func testRichBookInfosWordsAreTheMetadataEditors() throws {
        let editor = try Self.source("Views/Reader/MetadataEditorView.swift")

        // The editor says each word through `MetadataEditorWording`, which the phone's word equals.
        let pairs: [(phone: String, mac: String, shown: String)] = [
            (PhoneLibraryVocabulary.publisherField, MetadataEditorWording.publisherField,
             "TextField(MetadataEditorWording.publisherField, text: $editedEPUBMetadata.publisher)"),
            (PhoneLibraryVocabulary.publisherField, MetadataEditorWording.publisherField,
             "fieldLabel(MetadataEditorWording.publisherField, for: .publisher)"),
            (PhoneLibraryVocabulary.publicationDateField, MetadataEditorWording.publicationDateField,
             "TextField(MetadataEditorWording.publicationDateField, text: $editedEPUBMetadata.publicationDate)"),
            (PhoneLibraryVocabulary.publicationDateFieldLabel, MetadataEditorWording.publicationDateLabel,
             "fieldLabel(MetadataEditorWording.publicationDateLabel, for: .publicationDate)"),
            (PhoneLibraryVocabulary.authorField, MetadataEditorWording.authorField,
             "TextField(MetadataEditorWording.authorField, text: $editedEPUBMetadata.author)"),
            (PhoneLibraryVocabulary.authorField, MetadataEditorWording.authorField,
             "fieldLabel(MetadataEditorWording.authorField, for: .author)"),
            (PhoneLibraryVocabulary.isbnRow, MetadataEditorWording.isbnRow, "LabeledContent(MetadataEditorWording.isbnRow)"),
            (PhoneLibraryVocabulary.languageRow, MetadataEditorWording.languageRow, "LabeledContent(MetadataEditorWording.languageRow)"),
            (PhoneLibraryVocabulary.identifierRow, MetadataEditorWording.identifierRow, "LabeledContent(MetadataEditorWording.identifierRow)"),
            (PhoneLibraryVocabulary.epubVersionRow, MetadataEditorWording.epubVersionRow, "LabeledContent(MetadataEditorWording.epubVersionRow)"),
            (PhoneLibraryVocabulary.artistField, MetadataEditorWording.artistField,
             "TextField(MetadataEditorWording.artistField, text: $editedAudioMetadata.artist)"),
            (PhoneLibraryVocabulary.artistFieldLabel, MetadataEditorWording.artistLabel,
             "fieldLabel(MetadataEditorWording.artistLabel, for: .author)"),
            (PhoneLibraryVocabulary.albumField, MetadataEditorWording.albumField,
             "TextField(MetadataEditorWording.albumField, text: $editedAudioMetadata.album)"),
            (PhoneLibraryVocabulary.albumFieldLabel, MetadataEditorWording.albumLabel,
             "fieldLabel(MetadataEditorWording.albumLabel, for: .audioAlbum)"),
            (PhoneLibraryVocabulary.genreField, MetadataEditorWording.genreField,
             "TextField(MetadataEditorWording.genreField, text: $editedAudioMetadata.genre)"),
            (PhoneLibraryVocabulary.yearField, MetadataEditorWording.yearField,
             "TextField(MetadataEditorWording.yearField, text: $editedAudioMetadata.year)"),
            (PhoneLibraryVocabulary.durationRow, MetadataEditorWording.durationRow, "LabeledContent(MetadataEditorWording.durationRow)"),
            (PhoneLibraryVocabulary.titleField, MetadataEditorWording.titleField,
             "TextField(MetadataEditorWording.titleField, text: $editedAudioMetadata.title)"),
            (PhoneLibraryVocabulary.titleFieldLabel, MetadataEditorWording.bookTitleLabel,
             "fieldLabel(MetadataEditorWording.bookTitleLabel, for: .title)"),
        ]
        for pair in pairs {
            XCTAssertEqual(pair.phone, pair.mac, pair.shown)
            XCTAssertTrue(editor.contains(pair.shown), "The editor no longer says \(pair.shown)")
        }
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
