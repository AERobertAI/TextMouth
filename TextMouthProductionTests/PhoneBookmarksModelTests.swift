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
        XCTAssertEqual(PhoneBookmarksWording.remove, "Remove")
        XCTAssertEqual(PhoneBookmarksWording.jumpAnnouncement(to: madeThird), "Bookmark 3")
        XCTAssertEqual(PhoneBookmarksWording.emptyHelp, "Add Bookmark adds one at the current position.")
    }
}

/// `PhoneBookmarksVocabulary`: each word is the Mac's Bookmarks sheet's,
/// read from its own source.
final class PhoneBookmarksVocabularyTests: XCTestCase {
    /// Every inline word is in `BookmarkPanelView` as the phone has it.
    func testEveryWordIsTheMacsBookmarksSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/BookmarkPanelView.swift"),
            encoding: .utf8
        )
        let words = [
            "Text(\"\(PhoneBookmarksVocabulary.title)\")",
            "Button(\"\(PhoneBookmarksVocabulary.done)\")",
            "Label(\"\(PhoneBookmarksVocabulary.addBookmark)\", systemImage: \"plus\")",
            "Text(\"\(PhoneBookmarksVocabulary.addBookmark)\")",
            ".accessibilityLabel(\"\(PhoneBookmarksVocabulary.addBookmarkLabel)\")",
            "Text(\"\(PhoneBookmarksVocabulary.empty)\")",
            "\"\(PhoneBookmarksVocabulary.rowHint)\"",
            "TextField(\"\(PhoneBookmarksVocabulary.addNoteField)\", text: $noteText)",
            "TextField(\"\(PhoneBookmarksVocabulary.editNoteField)\", text: $noteText)",
            ".accessibilityLabel(\"\(PhoneBookmarksVocabulary.noteLabel)\")",
            ".accessibilityHint(\"\(PhoneBookmarksVocabulary.addNoteHint)\")",
            "Button(\"\(PhoneBookmarksVocabulary.cancel)\")",
            "Button(\"\(PhoneBookmarksVocabulary.add)\")",
            "Button(\"\(PhoneBookmarksVocabulary.save)\")",
            "Text(\"Edit Bookmark \\(bookmark.number)\")",
        ]

        for word in words {
            XCTAssertTrue(macView.contains(word), "The Mac's Bookmarks sheet no longer says \(word)")
        }
        XCTAssertEqual(PhoneBookmarksVocabulary.editTitle(number: 3), "Edit Bookmark 3")
    }
}
