import XCTest
@testable import TextMouth

/// `PhoneLibraryVocabulary`: each of the Mac's inline words the phone's
/// Library uses is read from the Mac's own view, word for word, so the two
/// apps can't drift apart unnoticed.
final class PhoneLibraryVocabularyTests: XCTestCase {
    /// The list's words are LibraryView's.
    func testTheListsWordsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        // Each phone word is the Mac's static, and the Mac's view shows that static (FR34).
        XCTAssertEqual(PhoneLibraryVocabulary.foldersHeader, LibraryListWording.foldersHeader)
        XCTAssertTrue(macView.contains("Text(LibraryListWording.foldersHeader)"))
        XCTAssertEqual(PhoneLibraryVocabulary.searchPrompt, LibraryListWording.searchPrompt)
        XCTAssertTrue(macView.contains("prompt: LibraryListWording.searchPrompt"))
        XCTAssertEqual(PhoneFolderVocabulary.newFolderTitle, LibrarySheetWording.newFolderTitle)
        XCTAssertTrue(macView.contains("Label(LibrarySheetWording.newFolderTitle, systemImage:"))
        XCTAssertEqual(PhoneLibraryVocabulary.newFolderLabel, LibraryListWording.createNewFolder)
        XCTAssertTrue(macView.contains(".accessibilityLabel(LibraryListWording.createNewFolder)"))
        XCTAssertEqual(PhoneLibraryVocabulary.sortTitle, LibraryListWording.sort)
        XCTAssertTrue(macView.contains("Label(LibraryListWording.sort, systemImage:"))
        XCTAssertEqual(PhoneLibraryVocabulary.applySortToSubfolders, LibraryListWording.applySortToSubfolders)
        XCTAssertTrue(macView.contains("Text(LibraryListWording.applySortToSubfolders)"))
    }

    /// A folder's commands are LibraryView's.
    func testAFoldersCommandsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertEqual(PhoneLibraryVocabulary.renameFolder, LibraryListWording.renameFolder)
        XCTAssertTrue(macView.contains("Button(LibraryListWording.renameFolder)"))
        XCTAssertEqual(PhoneLibraryVocabulary.moveFolder, LibraryListWording.moveFolder)
        XCTAssertTrue(macView.contains("Button(LibraryListWording.moveFolder)"))
        XCTAssertEqual(PhoneLibraryVocabulary.deleteFolder, LibraryListWording.deleteFolder)
        XCTAssertTrue(macView.contains("Button(LibraryListWording.deleteFolder, role: .destructive)"))
    }

    /// Book Info is the book row's own command, in LibrarySubviews.
    func testBookInfoIsTheRowsCommand() throws {
        let macView = try Self.source("Views/Library/LibrarySubviews.swift")

        XCTAssertEqual(PhoneLibraryVocabulary.bookInfo, LibrarySubviewWording.bookInfo)
        XCTAssertTrue(macView.contains("Button(LibrarySubviewWording.bookInfo)"))
    }

    /// The Continue row's visible title and hint are the Continue button's.
    func testTheContinueRowsWordsAreTheContinueButtons() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertEqual(
            LibraryListWording.continueVisible("Emma"),
            PhoneLibraryVocabulary.continueVisible("Emma")
        )
        XCTAssertTrue(macView.contains("Text(LibraryListWording.continueVisible(lastBook.title))"))
        XCTAssertEqual(PhoneLibraryVocabulary.continueHint, LibraryListWording.continueHint)
        XCTAssertTrue(macView.contains(".accessibilityHint(LibraryListWording.continueHint)"))
    }

    /// Removal's Cancel is the Mac's Remove Book question's.
    func testRemovalsCancelIsTheMacs() throws {
        let macView = try Self.source("Views/ContentView.swift")

        XCTAssertTrue(macView.contains("Button(LibraryWindowWording.cancel, role: .cancel)"))
    }

    /// Book Info's words are the Mac's simple Book Information sheet's, and
    /// what is said once saved is the Mac's reader's.
    func testBookInfosWordsAreTheMacs() throws {
        let sheet = try Self.source("Views/Library/LibrarySheetViews.swift")
        let reader = try Self.source("ViewModels/ReaderViewModel+Bookmarks.swift")

        // Each phone word is the Mac's static, and the sheet shows that static (FR34).
        let pairs: [(phone: String, mac: String, shown: String)] = [
            (PhoneLibraryVocabulary.bookInformation, LibrarySheetWording.bookInformation,
             "Text(LibrarySheetWording.bookInformation)"),
            (PhoneLibraryVocabulary.titleField, MetadataEditorWording.titleField,
             "TextField(MetadataEditorWording.titleField, text: $title)"),
            (PhoneLibraryVocabulary.titleFieldLabel, MetadataEditorWording.bookTitleLabel,
             "MetadataEditorWording.fieldLabel(MetadataEditorWording.bookTitleLabel, for: .title"),
            (PhoneLibraryVocabulary.authorField, MetadataEditorWording.authorField,
             "TextField(MetadataEditorWording.authorField, text: $author)"),
            (PhoneLibraryVocabulary.authorFieldLabel, LibrarySheetWording.bookAuthorLabel,
             "MetadataEditorWording.fieldLabel(LibrarySheetWording.bookAuthorLabel, for: .author"),
            (PhoneLibraryVocabulary.formatRow, MetadataEditorWording.formatRow,
             "LabeledContent(MetadataEditorWording.formatRow)"),
            (PhoneLibraryVocabulary.addedRow, LibrarySheetWording.addedRow,
             "LabeledContent(LibrarySheetWording.addedRow)"),
            (PhoneLibraryVocabulary.lastOpenedRow, LibrarySheetWording.lastOpenedRow,
             "LabeledContent(LibrarySheetWording.lastOpenedRow)"),
            (PhoneLibraryVocabulary.wordCountRow, LibrarySheetWording.wordCountRow,
             "LabeledContent(LibrarySheetWording.wordCountRow)"),
        ]
        for pair in pairs {
            XCTAssertEqual(pair.phone, pair.mac, pair.shown)
            XCTAssertTrue(sheet.contains(pair.shown), "The sheet no longer says \(pair.shown)")
        }
        XCTAssertEqual(PhoneAppWording.save, LibraryWindowWording.save)
        XCTAssertEqual(PhoneAppWording.cancel, LibraryWindowWording.cancel)
        XCTAssertTrue(sheet.contains("Button(LibraryWindowWording.save)"))
        XCTAssertTrue(sheet.contains("Button(LibraryWindowWording.cancel)"))
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
