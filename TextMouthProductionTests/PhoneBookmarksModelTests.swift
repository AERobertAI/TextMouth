import XCTest
@testable import TextMouth

/// `PhoneBookmarksModel`: the phone's Bookmarks sheet lists bookmarks as they
/// lie in the book, names them in the Mac's words, and moves focus by the
/// Mac's rules, by the spec's "The Bookmarks sheet".
final class PhoneBookmarksModelTests: XCTestCase {
    /// Three bookmarks made out of book order: the first made lies last.
    private let madeFirst = Bookmark(number: 1, chapterIndex: 1, characterOffset: 50, label: "Check this")
    private let madeSecond = Bookmark(number: 2, chapterIndex: 0, characterOffset: 300)
    private let madeThird = Bookmark(number: 3, chapterIndex: 0, characterOffset: 10)

    /// A model of the three, each in a heading named for its chapter.
    private var model: PhoneBookmarksModel {
        PhoneBookmarksModel(bookmarks: [madeFirst, madeSecond, madeThird]) { bookmark in
            bookmark.chapterIndex == 0 ? "The Battle" : nil
        }
    }

    /// The list follows the book, not the order the bookmarks were made in.
    func testTheListFollowsTheBook() {
        XCTAssertEqual(model.listed.map(\.number), [3, 2, 1])
    }

    /// Two bookmarks at one place go by their numbers.
    func testTwoAtOnePlaceGoByNumber() {
        let later = Bookmark(number: 5, chapterIndex: 0, characterOffset: 10)
        let earlier = Bookmark(number: 4, chapterIndex: 0, characterOffset: 10)

        XCTAssertEqual(PhoneBookmarksModel.bookOrder(of: [later, earlier]).map(\.number), [4, 5])
    }

    /// Each row reads the Mac's label, its heading named where there is one.
    func testEachRowReadsTheMacsLabel() {
        let rows = model.rows
        // Fewer rows than three fail here, never trap below.
        guard rows.count >= 3 else { return XCTFail("Three rows, not \(rows.count)") }

        XCTAssertEqual(rows[0].label, "Bookmark 3, The Battle, added \(madeThird.dateText)")
        XCTAssertEqual(rows[2].label, "Bookmark 1, Note: Check this, added \(madeFirst.dateText)")
        XCTAssertEqual(rows[2].shownTitle, "Bookmark 1")
        XCTAssertNil(rows[2].headingText)
    }

    /// Focus lands on the bookmark nearest before the place, else the first
    /// after it, else Add Bookmark.
    func testFocusLandsOnTheBookmarkNearestBeforeThePlace() {
        XCTAssertEqual(model.openingFocus(at: PhoneBookmarkPlace(chapterIndex: 0, characterOffset: 200)), .bookmark(madeThird.id))
        XCTAssertEqual(model.openingFocus(at: PhoneBookmarkPlace(chapterIndex: 0, characterOffset: 400)), .bookmark(madeSecond.id))
        XCTAssertEqual(model.openingFocus(at: PhoneBookmarkPlace(chapterIndex: 0, characterOffset: 0)), .bookmark(madeThird.id))

        let empty = PhoneBookmarksModel(bookmarks: []) { _ in nil }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.openingFocus(at: PhoneBookmarkPlace(chapterIndex: 0, characterOffset: 0)), .addButton)
    }

    /// After a delete, focus goes to the next row in the phone's order, else
    /// the row before, else Add Bookmark.
    func testFocusAfterADeleteGoesToTheNextRowThenTheOneBefore() {
        XCTAssertEqual(model.focus(after: .delete(madeSecond.id)), .bookmark(madeFirst.id))
        XCTAssertEqual(model.focus(after: .delete(madeFirst.id)), .bookmark(madeSecond.id))

        let alone = PhoneBookmarksModel(bookmarks: [madeSecond]) { _ in nil }
        XCTAssertEqual(alone.focus(after: .delete(madeSecond.id)), .addButton)
    }

    /// After an add, focus goes to the new bookmark; after a cancelled add,
    /// to Add Bookmark.
    func testFocusAfterAnAddGoesToTheNewBookmark() {
        XCTAssertEqual(model.focus(after: .add(madeSecond.id)), .bookmark(madeSecond.id))
        XCTAssertEqual(model.focus(after: .add(nil)), .addButton)
        XCTAssertEqual(model.focus(after: .cancelAdd), .addButton)
    }

    /// Only a bookmark with a note asks before it's removed.
    func testOnlyABookmarkWithANoteAsksFirst() {
        XCTAssertTrue(PhoneBookmarksModel.asksBeforeRemoving(madeFirst))
        XCTAssertFalse(PhoneBookmarksModel.asksBeforeRemoving(madeSecond))

        let blankNote = Bookmark(number: 9, chapterIndex: 0, characterOffset: 0, label: "  ")
        XCTAssertFalse(PhoneBookmarksModel.asksBeforeRemoving(blankNote))
    }

    /// The phone's own words are the spec's.
    func testThePhonesWordsAreTheSpecs() {
        XCTAssertEqual(PhoneBookmarksWording.removeQuestion(number: 3), "Remove Bookmark 3?")
        XCTAssertEqual(PhoneReaderWording.remove, "Remove")
        XCTAssertEqual(PhoneBookmarksWording.removeButton, "Remove")
        // The reader's own question and the sheet's are one: the same title and button.
        XCTAssertEqual(PhoneReaderWording.removeBookmarkTitle(madeThird), PhoneBookmarksWording.removeQuestion(number: 3))
        XCTAssertEqual(PhoneReaderWording.remove, PhoneBookmarksWording.removeButton)
        // A bookmark's number is an identifier: no digit grouping, whatever the region.
        XCTAssertEqual(PhoneBookmarksWording.removeQuestion(number: 1234), "Remove Bookmark 1234?")
        XCTAssertEqual(PhoneBookmarksWording.jumpAnnouncement(to: madeThird), "Bookmark 3")
        XCTAssertEqual(PhoneBookmarksWording.emptyHelp, "Add Bookmark adds one at the current position.")
    }
}

/// `PhoneBookmarksVocabulary`: each word is the Mac's Bookmarks sheet's, the
/// static the Mac's sheet shows, with its English as it was.
final class PhoneBookmarksVocabularyTests: XCTestCase {
    /// Every word the phone takes from the Mac's sheet is the Mac's own
    /// static, which the Mac's sheet shows where the word once sat inline
    /// (`shownAs`, read from its source), and its English has not changed.
    /// The words were inline literals of `BookmarkPanelView`, which this test
    /// found in its source; they became its localized statics (FR35), which
    /// both sheets read, so the source check looks for each static instead.
    func testEveryWordIsTheMacsBookmarksSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/BookmarkPanelView.swift"),
            encoding: .utf8
        )
        let words: [(phone: String, mac: String, english: String, shownAs: String)] = [
            (PhoneBookmarksVocabulary.title, BookmarkPanelView.title, "Bookmarks", "Text(Self.title)"),
            (PhoneBookmarksVocabulary.done, BookmarkPanelView.doneTitle, "Done", "Button(Self.doneTitle)"),
            (PhoneBookmarksVocabulary.addBookmark, BookmarkPanelView.addBookmarkTitle,
             "Add Bookmark", "Label(Self.addBookmarkTitle, systemImage: \"plus\")"),
            (PhoneBookmarksVocabulary.addBookmark, BookmarkPanelView.addBookmarkTitle,
             "Add Bookmark", "Text(Self.addBookmarkTitle)"),
            (PhoneBookmarksVocabulary.addBookmarkHint, BookmarkPanelView.addBookmarkHint,
             "Asks for an optional note, then marks the reading position.", ".accessibilityHint(Self.addBookmarkHint)"),
            (PhoneBookmarksVocabulary.empty, BookmarkPanelView.emptyList, "No bookmarks yet.", "Text(Self.emptyList)"),
            (PhoneBookmarksVocabulary.rowHint, BookmarkRow.hint,
             "Goes to this bookmark and closes the list.", ".accessibilityHint(row.accessibilityHintText)"),
            (PhoneBookmarksVocabulary.addNoteField, BookmarkPanelView.addNoteField,
             "Note (optional)", "TextField(Self.addNoteField, text: $noteText)"),
            (PhoneBookmarksVocabulary.editNoteField, BookmarkPanelView.editNoteField,
             "Note", "TextField(Self.editNoteField, text: $noteText)"),
            (PhoneBookmarksVocabulary.noteLabel, BookmarkPanelView.noteLabel,
             "Bookmark note", ".accessibilityLabel(Self.noteLabel)"),
            (PhoneBookmarksVocabulary.cancel, BookmarkPanelView.cancelTitle, "Cancel", "Button(Self.cancelTitle)"),
            (PhoneBookmarksVocabulary.add, BookmarkPanelView.addTitle, "Add", "Button(Self.addTitle)"),
            (PhoneBookmarksVocabulary.save, BookmarkPanelView.saveTitle, "Save", "Button(Self.saveTitle)"),
            (PhoneBookmarksVocabulary.editTitle(number: 3), BookmarkPanelView.editTitle(number: 3),
             "Edit Bookmark 3", "Text(Self.editTitle(number: bookmark.number))"),
        ]

        for word in words {
            XCTAssertEqual(word.phone, word.mac, "The phone's word is not the Mac's \(word.shownAs)")
            XCTAssertEqual(word.mac, word.english, "The Mac's \(word.shownAs) changed its English")
            XCTAssertTrue(macView.contains(word.shownAs), "The Mac's Bookmarks sheet no longer shows \(word.shownAs)")
        }
    }

    /// The iPhone's sheets say Cancel, Save, and Remove through the Mac's localized words, never through
    /// `PhoneAppWording`'s English or `PhoneReaderWording`'s copies, which left the question half Spanish
    /// (finding 4 of the pilot's review). The source is read, since the language cannot change in the test host.
    func testThePhonesBookmarkSheetsShowTheMacsWords() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
        }
        let sheet = try source("Platform/iOS/Views/Reader/PhoneBookmarksSheet.swift")
        XCTAssertFalse(sheet.contains("PhoneAppWording"), "The Bookmarks sheet still says an English word of PhoneAppWording")
        XCTAssertFalse(sheet.contains("PhoneReaderWording.remove"), "The Bookmarks sheet still says the reader's copy of Remove")
        XCTAssertEqual(sheet.components(separatedBy: "PhoneBookmarksVocabulary.cancel").count - 1, 2, "Cancel in the question and the note sheet")
        XCTAssertTrue(sheet.contains("doneTitle: PhoneBookmarksVocabulary.save"))
        XCTAssertTrue(sheet.contains("Button(PhoneBookmarksWording.removeButton, role: .destructive)"))
        // The reader's own question: its title forwards to the sheet's, and its buttons are the Mac's words.
        let reader = try source("Platform/iOS/Views/Reader/PhoneReaderView.swift")
        XCTAssertTrue(reader.contains("Button(PhoneBookmarksVocabulary.cancel, role: .cancel)"))
        XCTAssertFalse(reader.contains("PhoneAppWording.cancel"))
    }
}
